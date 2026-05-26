const std = @import("std");

const HostApi = extern struct {
    api_version: u32,
    register_syntax_block: *const fn (host: *HostApi, name: [*:0]const u8, syntax: *const BlockSyntax, handler: BlockHandler) callconv(.c) c_int,
    register_help_section: *const fn (host: *HostApi, id: [*:0]const u8, text: [*:0]const u8) callconv(.c) c_int,
    register_cli_flag: *const fn (host: *HostApi, name: [*:0]const u8, help: ?[*:0]const u8, mandatory: c_int) callconv(.c) c_int,
    register_module: *const fn (host: *HostApi, name: [*:0]const u8, path: [*:0]const u8) callconv(.c) c_int,
    register_link_flag: *const fn (host: *HostApi, flag: [*:0]const u8) callconv(.c) c_int,
    diagnostic: *const fn (host: *HostApi, level: c_int, file: ?[*:0]const u8, line: u32, column: u32, message: [*:0]const u8, hint: ?[*:0]const u8) callconv(.c) void,
    resolve_type_size: *const fn (host: *HostApi, file: [*:0]const u8, type_name: [*:0]const u8) callconv(.c) i32,
    get_cli_flag: *const fn (host: *HostApi, name: [*:0]const u8) callconv(.c) ?[*:0]const u8,
};

const BlockSyntax = extern struct { mode: c_int, terminator: ?[*:0]const u8 };
const BlockInput = extern struct { file: [*:0]const u8, line: u32, column: u32, raw_source: [*]const u8, raw_source_len: u32 };
const SourceMapEntry = extern struct { generated_offset: u32, original_line: u32, original_column: u32 };
const BlockOutput = extern struct {
    generated_zlang_source: [*]const u8,
    generated_zlang_source_len: u32,
    source_map: ?[*]const SourceMapEntry,
    source_map_len: u32,
};
const BlockHandler = *const fn (host: *HostApi, input: *const BlockInput, output: *BlockOutput) callconv(.c) c_int;

const ProbeResult = extern struct {
    api_min: u32,
    api_max: u32,
    name: [*:0]const u8,
    version: [*:0]const u8,
    requires_host_features: ?[*:null]const ?[*:0]const u8,
};

const PluginDesc = extern struct {
    api_min: u32,
    api_max: u32,
    name: [*:0]const u8,
    version: [*:0]const u8,
    register_plugin: *const fn (host: *HostApi) callconv(.c) c_int,
    session_begin: ?*const fn (host: *HostApi) callconv(.c) void,
    session_end: ?*const fn (host: *HostApi) callconv(.c) void,
};

var probe_singleton: ProbeResult = .{
    .api_min = 1,
    .api_max = 3,
    .name = "zlisp",
    .version = "0.1.0",
    .requires_host_features = null,
};

var desc_singleton: PluginDesc = .{
    .api_min = 1,
    .api_max = 3,
    .name = "zlisp",
    .version = "0.1.0",
    .register_plugin = registerPlugin,
    .session_begin = sessionBegin,
    .session_end = sessionEnd,
};

const alloc = std.heap.c_allocator;
var output_buf: std.ArrayList(u8) = .empty;

const NodeKind = enum { list, symbol, number, string };
const Node = struct {
    kind: NodeKind,
    text: []const u8,
    children: std.ArrayList(*Node) = .empty,

    fn deinit(self: *Node) void {
        for (self.children.items) |c| {
            c.deinit();
            alloc.destroy(c);
        }
        self.children.deinit(alloc);
    }
};

fn makeNode(kind: NodeKind, text: []const u8) !*Node {
    const n = try alloc.create(Node);
    n.* = .{ .kind = kind, .text = text };
    return n;
}

const ParseError = error{ Unbalanced, UnterminatedString, OutOfMemory };

const Parser = struct {
    src: []const u8,
    pos: usize = 0,

    fn skipWs(self: *Parser) void {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                self.pos += 1;
            } else if (c == ';') {
                while (self.pos < self.src.len and self.src[self.pos] != '\n') : (self.pos += 1) {}
            } else break;
        }
    }

    fn parseOne(self: *Parser) ParseError!?*Node {
        self.skipWs();
        if (self.pos >= self.src.len) return null;
        const c = self.src[self.pos];
        if (c == ')') return null;
        if (c == '(') {
            self.pos += 1;
            const node = try makeNode(.list, "");
            errdefer {
                node.deinit();
                alloc.destroy(node);
            }
            while (true) {
                const child = try self.parseOne() orelse break;
                try node.children.append(alloc, child);
            }
            self.skipWs();
            if (self.pos >= self.src.len or self.src[self.pos] != ')') return error.Unbalanced;
            self.pos += 1;
            return node;
        }
        if (c == '"') {
            self.pos += 1;
            const start = self.pos;
            while (self.pos < self.src.len and self.src[self.pos] != '"') {
                if (self.src[self.pos] == '\\' and self.pos + 1 < self.src.len) self.pos += 2 else self.pos += 1;
            }
            if (self.pos >= self.src.len) return error.UnterminatedString;
            const text = self.src[start..self.pos];
            self.pos += 1;
            return try makeNode(.string, text);
        }
        const start = self.pos;
        while (self.pos < self.src.len) {
            const cc = self.src[self.pos];
            if (cc == ' ' or cc == '\t' or cc == '\n' or cc == '\r' or cc == '(' or cc == ')') break;
            self.pos += 1;
        }
        const text = self.src[start..self.pos];
        const is_num = text.len > 0 and (std.ascii.isDigit(text[0]) or (text[0] == '-' and text.len > 1 and std.ascii.isDigit(text[1])));
        return try makeNode(if (is_num) .number else .symbol, text);
    }
};

// --- Macro system -----------------------------------------------------------
// defmacro defines a template macro. Expansion is substitution-based: every
// occurrence of a parameter symbol in the body is replaced by the matching
// argument subtree, then the result is re-expanded so macros can build on
// macros. All nodes produced during expansion are tracked in `macro_pool` and
// freed together; originals (owned by the parse forms) are never shared.

const MacroDef = struct {
    params: std.ArrayList([]const u8),
    body: *Node,
};

// `macros` and `session_pool` persist for the whole compilation (across every
// `lisp { ... }` block in a file), so a macro defined in one block is usable in
// later ones. Macro bodies are deep-copied with duplicated text into
// `session_pool` because the per-block parse forms and raw source are freed
// after each handler call. `expand_pool` is per-block scratch for expansion.
var macros: std.StringHashMap(MacroDef) = undefined;
var macros_ready: bool = false;
var session_pool: std.ArrayList(*Node) = .empty;
var expand_pool: std.ArrayList(*Node) = .empty;

fn trackNode(kind: NodeKind, text: []const u8) !*Node {
    const n = try alloc.create(Node);
    n.* = .{ .kind = kind, .text = text };
    try expand_pool.append(alloc, n);
    return n;
}

fn cloneTree(node: *Node) ParseError!*Node {
    const n = try trackNode(node.kind, node.text);
    for (node.children.items) |c| try n.children.append(alloc, try cloneTree(c));
    return n;
}

fn clonePersistent(node: *Node) ParseError!*Node {
    const txt = try alloc.dupe(u8, node.text);
    const n = try alloc.create(Node);
    n.* = .{ .kind = node.kind, .text = txt };
    try session_pool.append(alloc, n);
    for (node.children.items) |c| try n.children.append(alloc, try clonePersistent(c));
    return n;
}

fn resetMacros() void {
    if (macros_ready) {
        var it = macros.valueIterator();
        while (it.next()) |v| {
            for (v.params.items) |p| alloc.free(p);
            v.params.deinit(alloc);
        }
        var kit = macros.keyIterator();
        while (kit.next()) |k| alloc.free(k.*);
        macros.deinit();
    }
    for (session_pool.items) |n| {
        alloc.free(n.text);
        n.children.deinit(alloc);
        alloc.destroy(n);
    }
    session_pool.clearRetainingCapacity();
    macros = std.StringHashMap(MacroDef).init(alloc);
    macros_ready = true;
}

fn instantiate(tmpl: *Node, params: [][]const u8, args: []*Node) ParseError!*Node {
    if (tmpl.kind == .symbol) {
        for (params, 0..) |p, i| {
            if (std.mem.eql(u8, p, tmpl.text) and i < args.len) return cloneTree(args[i]);
        }
        return cloneTree(tmpl);
    }
    if (tmpl.kind != .list) return cloneTree(tmpl);
    const n = try trackNode(.list, tmpl.text);
    for (tmpl.children.items) |c| try n.children.append(alloc, try instantiate(c, params, args));
    return n;
}

fn expand(node: *Node, depth: u32) ParseError!*Node {
    if (node.kind == .list and node.children.items.len > 0) {
        const head = node.children.items[0];
        if (head.kind == .symbol and depth < 64) {
            if (macros.get(head.text)) |m| {
                const inst = try instantiate(m.body, m.params.items, node.children.items[1..]);
                return expand(inst, depth + 1);
            }
        }
    }
    if (node.kind != .list) return cloneTree(node);
    const n = try trackNode(node.kind, node.text);
    for (node.children.items) |c| try n.children.append(alloc, try expand(c, depth));
    return n;
}

fn registerMacro(node: *Node) ParseError!void {
    const items = node.children.items;
    if (items.len < 4) return; // (defmacro name (params) body...)
    const name = items[1];
    const params_node = items[2];
    const body_forms = items[3..];

    var params: std.ArrayList([]const u8) = .empty;
    for (params_node.children.items) |p| try params.append(alloc, try alloc.dupe(u8, p.text));

    var body: *Node = undefined;
    if (body_forms.len == 1) {
        body = try clonePersistent(body_forms[0]);
    } else {
        const do_node = try alloc.create(Node);
        do_node.* = .{ .kind = .list, .text = try alloc.dupe(u8, "") };
        try session_pool.append(alloc, do_node);
        const do_sym = try alloc.create(Node);
        do_sym.* = .{ .kind = .symbol, .text = try alloc.dupe(u8, "do") };
        try session_pool.append(alloc, do_sym);
        try do_node.children.append(alloc, do_sym);
        for (body_forms) |bf| try do_node.children.append(alloc, try clonePersistent(bf));
        body = do_node;
    }
    try macros.put(try alloc.dupe(u8, name.text), .{ .params = params, .body = body });
}

fn isMacroDef(node: *Node) bool {
    return node.kind == .list and node.children.items.len > 0 and
        node.children.items[0].kind == .symbol and
        std.mem.eql(u8, node.children.items[0].text, "defmacro");
}

fn emit(s: []const u8) void {
    output_buf.appendSlice(alloc, s) catch {};
}

fn emitFmt(comptime fmt: []const u8, args: anytype) void {
    output_buf.print(alloc, fmt, args) catch {};
}

const binops = [_]struct { sym: []const u8, op: []const u8 }{
    .{ .sym = "+", .op = "+" },
    .{ .sym = "-", .op = "-" },
    .{ .sym = "*", .op = "*" },
    .{ .sym = "/", .op = "/" },
    .{ .sym = "%", .op = "%" },
    .{ .sym = "<", .op = "<" },
    .{ .sym = ">", .op = ">" },
    .{ .sym = "<=", .op = "<=" },
    .{ .sym = ">=", .op = ">=" },
    .{ .sym = "=", .op = "==" },
    .{ .sym = "!=", .op = "!=" },
    .{ .sym = "and", .op = "&&" },
    .{ .sym = "or", .op = "||" },
};

fn findBinop(sym: []const u8) ?[]const u8 {
    for (binops) |b| {
        if (std.mem.eql(u8, b.sym, sym)) return b.op;
    }
    return null;
}

fn emitExpr(node: *Node) void {
    switch (node.kind) {
        .number => emit(node.text),
        .symbol => emit(node.text),
        .string => {
            emit("\"");
            emit(node.text);
            emit("\"");
        },
        .list => {
            if (node.children.items.len == 0) {
                emit("0");
                return;
            }
            const head = node.children.items[0];
            const args = node.children.items[1..];
            if (head.kind == .symbol) {
                if (findBinop(head.text)) |op| {
                    if (args.len == 1) {
                        emit("(");
                        if (std.mem.eql(u8, op, "-")) emit("-");
                        emitExpr(args[0]);
                        emit(")");
                        return;
                    }
                    emit("(");
                    for (args, 0..) |a, i| {
                        if (i != 0) {
                            emit(" ");
                            emit(op);
                            emit(" ");
                        }
                        emitExpr(a);
                    }
                    emit(")");
                    return;
                }
                if (std.mem.eql(u8, head.text, "not")) {
                    emit("(!");
                    emitExpr(args[0]);
                    emit(")");
                    return;
                }
                if (std.mem.eql(u8, head.text, "do")) {
                    emit("(");
                    for (args, 0..) |a, i| {
                        if (i != 0) emit(", ");
                        emitExpr(a);
                    }
                    emit(")");
                    return;
                }
                if (std.mem.startsWith(u8, head.text, "@")) {
                    emit(head.text);
                    emit("(");
                    for (args, 0..) |a, i| {
                        if (i != 0) emit(", ");
                        emitExpr(a);
                    }
                    emit(")");
                    return;
                }
                emit(head.text);
                emit("(");
                for (args, 0..) |a, i| {
                    if (i != 0) emit(", ");
                    emitExpr(a);
                }
                emit(")");
                return;
            }
            emit("/*unhandled list*/");
        },
    }
}

fn emitStmt(node: *Node) void {
    if (node.kind != .list or node.children.items.len == 0) {
        emitExpr(node);
        emit(";\n");
        return;
    }
    const head = node.children.items[0];
    if (head.kind != .symbol) {
        emitExpr(node);
        emit(";\n");
        return;
    }
    const args = node.children.items[1..];

    if (std.mem.eql(u8, head.text, "set")) {
        emitExpr(args[0]);
        emit(" = ");
        emitExpr(args[1]);
        emit(";\n");
        return;
    }
    if (std.mem.eql(u8, head.text, "let")) {
        emitLetBindings(args[0]);
        for (args[1..]) |s| emitStmt(s);
        return;
    }
    if (std.mem.eql(u8, head.text, "for")) {
        // (for (i start end [step]) body...)
        const spec = args[0];
        const it = spec.children.items;
        const var_name = it[0].text;
        emitFmt("for i32 {s} = ", .{var_name});
        emitExpr(it[1]);
        emitFmt("; {s} < ", .{var_name});
        emitExpr(it[2]);
        if (it.len > 3) {
            emitFmt("; {s} += ", .{var_name});
            emitExpr(it[3]);
        } else {
            emitFmt("; {s}++", .{var_name});
        }
        emit(" {\n");
        for (args[1..]) |s| emitStmt(s);
        emit("}\n");
        return;
    }
    if (std.mem.eql(u8, head.text, "if")) {
        emit("if (");
        emitExpr(args[0]);
        emit(") {\n");
        emitStmt(args[1]);
        emit("}");
        if (args.len > 2) {
            emit(" else {\n");
            emitStmt(args[2]);
            emit("}");
        }
        emit("\n");
        return;
    }
    if (std.mem.eql(u8, head.text, "while")) {
        emit("for (");
        emitExpr(args[0]);
        emit(") {\n");
        for (args[1..]) |s| emitStmt(s);
        emit("}\n");
        return;
    }
    if (std.mem.eql(u8, head.text, "when")) {
        emit("if (");
        emitExpr(args[0]);
        emit(") {\n");
        for (args[1..]) |s| emitStmt(s);
        emit("}\n");
        return;
    }
    if (std.mem.eql(u8, head.text, "unless")) {
        emit("if (!(");
        emitExpr(args[0]);
        emit(")) {\n");
        for (args[1..]) |s| emitStmt(s);
        emit("}\n");
        return;
    }
    if (std.mem.eql(u8, head.text, "cond")) {
        emitCond(args, null);
        return;
    }
    if (std.mem.eql(u8, head.text, "return")) {
        emit("return ");
        if (args.len > 0) emitExpr(args[0]) else emit("0");
        emit(";\n");
        return;
    }
    if (std.mem.eql(u8, head.text, "do")) {
        for (args) |s| emitStmt(s);
        return;
    }
    emitExpr(node);
    emit(";\n");
}

// Each binding is (name value) -> i32, or (name type value) -> typed.
fn emitLetBindings(bindings: *Node) void {
    for (bindings.children.items) |b| {
        const it = b.children.items;
        if (it.len >= 3) {
            emit(it[1].text);
            emit(" ");
            emitExpr(it[0]);
            emit(" = ");
            emitExpr(it[2]);
        } else {
            emit("i32 ");
            emitExpr(it[0]);
            emit(" = ");
            emitExpr(it[1]);
        }
        emit(";\n");
    }
}

fn emitCondBody(body: []*Node, ret_type: ?[]const u8) void {
    if (ret_type) |rt| {
        if (body.len == 0) {
            if (!std.mem.eql(u8, rt, "void")) emit("return 0;\n");
            return;
        }
        for (body[0 .. body.len - 1]) |s| emitStmt(s);
        emitReturnFrom(body[body.len - 1], rt);
    } else {
        for (body) |s| emitStmt(s);
    }
}

// (cond (test body...) ... (else body...)) -> if / else if / else chain.
fn emitCond(clauses: []*Node, ret_type: ?[]const u8) void {
    var first = true;
    for (clauses) |clause| {
        if (clause.kind != .list or clause.children.items.len == 0) continue;
        const test_node = clause.children.items[0];
        const body = clause.children.items[1..];
        const is_else = test_node.kind == .symbol and std.mem.eql(u8, test_node.text, "else");
        if (!first) emit(" else ");
        if (is_else) {
            emit("{\n");
        } else {
            emit("if (");
            emitExpr(test_node);
            emit(") {\n");
        }
        emitCondBody(body, ret_type);
        emit("}");
        first = false;
        if (is_else) break;
    }
    emit("\n");
}

fn emitDefn(node: *Node) void {
    const args = node.children.items[1..];
    const name = args[0];
    const params = args[1];
    const body = args[2..];

    emitFmt("fun {s}(", .{name.text});
    for (params.children.items, 0..) |p, i| {
        if (i != 0) emit(", ");
        if (p.kind == .list and p.children.items.len == 2) {
            emitFmt("{s}: {s}", .{ p.children.items[0].text, p.children.items[1].text });
        } else {
            emitFmt("{s}: i32", .{p.text});
        }
    }
    var ret_type: []const u8 = "i32";
    var body_start: usize = 0;
    if (body.len >= 2 and body[0].kind == .symbol and std.mem.eql(u8, body[0].text, "->")) {
        ret_type = body[1].text;
        body_start = 2;
    }
    emitFmt(") >> {s} {{\n", .{ret_type});
    if (body.len > body_start) {
        const last_idx = body.len - 1;
        var i: usize = body_start;
        while (i < last_idx) : (i += 1) emitStmt(body[i]);
        emitReturnFrom(body[last_idx], ret_type);
    } else if (std.mem.eql(u8, ret_type, "i32")) {
        emit("return 0;\n");
    }
    emit("}\n");
}

fn emitReturnFrom(node: *Node, ret_type: []const u8) void {
    if (node.kind == .list and node.children.items.len > 0 and node.children.items[0].kind == .symbol) {
        const lh = node.children.items[0].text;
        const args = node.children.items[1..];

        if (std.mem.eql(u8, lh, "return")) {
            emitStmt(node);
            return;
        }
        if (std.mem.eql(u8, lh, "if") and args.len >= 2) {
            emit("if (");
            emitExpr(args[0]);
            emit(") {\n");
            emitReturnFrom(args[1], ret_type);
            emit("}");
            if (args.len > 2) {
                emit(" else {\n");
                emitReturnFrom(args[2], ret_type);
                emit("}");
            } else if (!std.mem.eql(u8, ret_type, "void")) {
                emit(" else { return 0; }");
            }
            emit("\n");
            return;
        }
        if (std.mem.eql(u8, lh, "do") and args.len > 0) {
            for (args[0 .. args.len - 1]) |s| emitStmt(s);
            emitReturnFrom(args[args.len - 1], ret_type);
            return;
        }
        if (std.mem.eql(u8, lh, "let") and args.len >= 2) {
            emitLetBindings(args[0]);
            const body = args[1..];
            for (body[0 .. body.len - 1]) |s| emitStmt(s);
            emitReturnFrom(body[body.len - 1], ret_type);
            return;
        }
        if (std.mem.eql(u8, lh, "for")) {
            emitStmt(node);
            if (!std.mem.eql(u8, ret_type, "void")) emit("return 0;\n");
            return;
        }
        if (std.mem.eql(u8, lh, "cond")) {
            emitCond(args, ret_type);
            return;
        }
        if (std.mem.eql(u8, lh, "while") or std.mem.eql(u8, lh, "set") or
            std.mem.eql(u8, lh, "when") or std.mem.eql(u8, lh, "unless"))
        {
            emitStmt(node);
            if (!std.mem.eql(u8, ret_type, "void")) emit("return 0;\n");
            return;
        }
    }
    if (std.mem.eql(u8, ret_type, "void")) {
        emitStmt(node);
        return;
    }
    emit("return ");
    emitExpr(node);
    emit(";\n");
}

fn lispHandler(host: *HostApi, input: *const BlockInput, output: *BlockOutput) callconv(.c) c_int {
    _ = host;
    output_buf.clearRetainingCapacity();

    const raw = input.raw_source[0..input.raw_source_len];
    var parser = Parser{ .src = raw };
    var forms: std.ArrayList(*Node) = .empty;
    defer {
        for (forms.items) |f| {
            f.deinit();
            alloc.destroy(f);
        }
        forms.deinit(alloc);
    }
    while (true) {
        const n = parser.parseOne() catch return 1;
        const node = n orelse break;
        forms.append(alloc, node) catch return 1;
    }

    // Macro pass: register defmacro forms, then expand everything else.
    // `macros`/`session_pool` persist across blocks (set up in sessionBegin);
    // `expand_pool` is scratch freed at the end of this block.
    if (!macros_ready) resetMacros();
    defer {
        for (expand_pool.items) |n| {
            n.children.deinit(alloc);
            alloc.destroy(n);
        }
        expand_pool.clearRetainingCapacity();
    }

    var prog: std.ArrayList(*Node) = .empty;
    defer prog.deinit(alloc);
    for (forms.items) |f| {
        if (isMacroDef(f)) {
            registerMacro(f) catch return 1;
            continue;
        }
        prog.append(alloc, expand(f, 0) catch return 1) catch return 1;
    }

    var all_defns = prog.items.len > 0;
    for (prog.items) |f| {
        if (f.kind != .list or f.children.items.len == 0) {
            all_defns = false;
            break;
        }
        const h = f.children.items[0];
        if (h.kind != .symbol or !std.mem.eql(u8, h.text, "defn")) {
            all_defns = false;
            break;
        }
    }

    if (all_defns) {
        for (prog.items) |f| emitDefn(f);
    } else {
        for (prog.items) |f| {
            if (f.kind == .list and f.children.items.len > 0 and f.children.items[0].kind == .symbol and std.mem.eql(u8, f.children.items[0].text, "defn")) {
                continue;
            }
            emitStmt(f);
        }
    }

    output.* = .{
        .generated_zlang_source = output_buf.items.ptr,
        .generated_zlang_source_len = @intCast(output_buf.items.len),
        .source_map = null,
        .source_map_len = 0,
    };
    return 0;
}

fn sessionBegin(host: *HostApi) callconv(.c) void {
    _ = host;
    output_buf.clearRetainingCapacity();
    resetMacros();
}

fn sessionEnd(host: *HostApi) callconv(.c) void {
    _ = host;
    if (macros_ready) {
        var it = macros.valueIterator();
        while (it.next()) |v| {
            for (v.params.items) |p| alloc.free(p);
            v.params.deinit(alloc);
        }
        var kit = macros.keyIterator();
        while (kit.next()) |k| alloc.free(k.*);
        macros.deinit();
        macros_ready = false;
    }
    for (session_pool.items) |n| {
        alloc.free(n.text);
        n.children.deinit(alloc);
        alloc.destroy(n);
    }
    session_pool.clearRetainingCapacity();
}

fn registerPlugin(host: *HostApi) callconv(.c) c_int {
    const syntax = BlockSyntax{ .mode = 1, .terminator = null };
    _ = host.register_syntax_block(host, "lisp", &syntax, lispHandler);
    return 0;
}

export fn zlang_plugin_probe(host_api_version: u32) callconv(.c) ?*ProbeResult {
    _ = host_api_version;
    return &probe_singleton;
}

export fn zlang_plugin_init(host: *HostApi) callconv(.c) ?*PluginDesc {
    _ = host;
    return &desc_singleton;
}

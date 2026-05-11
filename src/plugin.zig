const std = @import("std");

const HostApi = extern struct {
    api_version: u32,
    register_syntax_block: *const fn (host: *HostApi, name: [*:0]const u8, syntax: *const BlockSyntax, handler: BlockHandler) callconv(.c) c_int,
    register_help_section: *const fn (host: *HostApi, id: [*:0]const u8, text: [*:0]const u8) callconv(.c) c_int,
    register_cli_flag: *const fn (host: *HostApi, name: [*:0]const u8, help: ?[*:0]const u8, mandatory: c_int) callconv(.c) c_int,
    register_module: *const fn (host: *HostApi, name: [*:0]const u8, path: [*:0]const u8) callconv(.c) c_int,
    register_link_flag: *const fn (host: *HostApi, flag: [*:0]const u8) callconv(.c) c_int,
    diagnostic: *const fn (host: *HostApi, level: c_int, file: ?[*:0]const u8, line: u32, column: u32, message: [*:0]const u8, hint: ?[*:0]const u8) callconv(.c) void,
};

const BlockSyntax = extern struct { mode: c_int, terminator: ?[*:0]const u8 };
const BlockInput = extern struct { file: [*:0]const u8, line: u32, column: u32, raw_source: [*]const u8, raw_source_len: u32 };
const BlockOutput = extern struct { generated_zlang_source: [*]const u8, generated_zlang_source_len: u32 };
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
};

var probe_singleton: ProbeResult = .{
    .api_min = 1,
    .api_max = 1,
    .name = "zlisp",
    .version = "0.1.0",
    .requires_host_features = null,
};

var desc_singleton: PluginDesc = .{
    .api_min = 1,
    .api_max = 1,
    .name = "zlisp",
    .version = "0.1.0",
    .register_plugin = registerPlugin,
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
        const bindings = args[0];
        for (bindings.children.items) |b| {
            emit("i32 ");
            emitExpr(b.children.items[0]);
            emit(" = ");
            emitExpr(b.children.items[1]);
            emit(";\n");
        }
        for (args[1..]) |s| emitStmt(s);
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
            const bindings = args[0];
            for (bindings.children.items) |b| {
                emit("i32 ");
                emitExpr(b.children.items[0]);
                emit(" = ");
                emitExpr(b.children.items[1]);
                emit(";\n");
            }
            const body = args[1..];
            for (body[0 .. body.len - 1]) |s| emitStmt(s);
            emitReturnFrom(body[body.len - 1], ret_type);
            return;
        }
        if (std.mem.eql(u8, lh, "while") or std.mem.eql(u8, lh, "set")) {
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

    var all_defns = true;
    for (forms.items) |f| {
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
        for (forms.items) |f| emitDefn(f);
    } else {
        for (forms.items) |f| {
            if (f.kind == .list and f.children.items.len > 0 and f.children.items[0].kind == .symbol and std.mem.eql(u8, f.children.items[0].text, "defn")) {
                continue;
            }
            emitStmt(f);
        }
    }

    output.* = .{
        .generated_zlang_source = output_buf.items.ptr,
        .generated_zlang_source_len = @intCast(output_buf.items.len),
    };
    return 0;
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

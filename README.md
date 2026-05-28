# zlisp.zlx

ZLang extension that embeds a small Lisp dialect via `lisp { ... }` blocks.

## Build

```sh
./build.sh
```

Compiles `src/plugin.zig` into `zlisp.so`, then packs
`manifest.zon` + `zlisp.so` into `zlisp.zlx`. Both intermediates
are gitignored.

## Install

```sh
zlang module install ./zlisp.zlx
```

## Use

Top-level: define functions callable from zlang.

```zl
lisp {
    (defn add (a b) (+ a b))
    (defn fact (n)
        (if (<= n 1)
            1
            (* n (fact (- n 1)))))
}

fun main() >> i32 {
    @printf("%d\n", add(3, 4));
    @printf("%d\n", fact(6));
    return 0;
}
```

Inside a function body: emits zlang statements.

```zl
fun main() >> i32 {
    i32 x = 0;
    lisp {
        (set x (+ 10 20))
    };
    @printf("%d\n", x);
    return 0;
}
```

## Bidirectional calls

A bare symbol in head position is emitted as a zlang call, so Lisp
can call any zlang function by name and any zlang code can call a
function defined by `(defn ...)` directly:

```zl
fun zlang_double(x: i32) >> i32 { return x * 2; }

lisp {
    (defn boosted (n) (zlang_double (+ n 1)))
}

fun main() >> i32 {
    @printf("%d\n", boosted(5));     ?? -> 12
    return 0;
}
```

## Supported forms

- `(defn name (a b) body...)` — define a function. Last expression
  is returned. Optional explicit return type:
  `(defn name (a b) -> i64 body...)`.
- Parameter types default to `i32`. Specify via
  `((a i32) (b i64))` form.
- `(let ((x 1) (y 2)) body...)` — declare locals, run body. A binding
  may carry a type: `(x i64 5)` declares `i64 x = 5`.
- `(set name expr)` — assignment.
- `(if cond then else)` — both as statement and as the last
  expression of a defn (each branch then returns).
- `(cond (test body...) ... (else body...))` — multi-way branch,
  usable as a statement or in tail position.
- `(when cond body...)` / `(unless cond body...)` — one-armed guards.
- `(while cond body...)` — loop.
- `(for (i start end [step]) body...)` — counting loop, expands to a
  C-style `for`.
- `(do a b ...)` — sequence; last is the value.
- `(return expr)` — explicit return.
- Arithmetic: `+ - * / %` (variadic for the first four).
- Comparisons: `< > <= >= = !=`.
- Boolean: `and or not`.
- Bitwise: `bit-and bit-or bit-xor shl shr` (variadic).
- Memory: `(aref a i)` → `a[i]`, `(aset a i v)` → `a[i] = v`,
  `(addr x)` → `&x`, `(deref p)` → `*p`, `(store p v)` → `*p = v`.
- `(cast x T)` → `x as T`. `nil` → `null`.
- Calls: `(name args...)` translates to `name(args...)`. Names
  starting with `@` are emitted as zlang built-in calls
  (e.g. `(@printf "%d\n" x)`).
- Numbers, identifiers, double-quoted strings.

## Macros

`(defmacro name (params) body...)` defines a compile-time template
macro. Calls are expanded by substituting arguments into the body,
then re-expanded so macros can build on other macros. Macros defined
in one `lisp { ... }` block are visible in every later block of the
same file.

```zl
lisp {
    (defmacro square (x) (* x x))
    (defmacro inc! (v) (set v (+ v 1)))
    (defn hypot_sq (a b) (+ (square a) (square b)))
}
```

Substitution is unhygienic (no gensym yet), so pick distinct names
for macro-introduced bindings.

## Status

v0.2.0 targets `linux-x86_64`. Has template macros, `cond`/`when`/
`unless`, `for`, typed `let`, bitwise and pointer/array forms. No
closures, no hygienic macros, no list runtime, no tail-call
elimination beyond what LLVM does for the generated zlang functions.

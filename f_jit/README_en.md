# f_jit — Bytecode compiler and JIT for a Cangjie dialect

`f_jit` compiles a **Cangjie dialect** source into architecture-neutral bytecode (`.fbc`) and executes it
with three engines: an **interpreter**, an **x86_64 backend**, and an **aarch64 backend**. Embedded in a
host application, the compiled code is callable like a normal function (`JitFunction.call<T>`) and can
interoperate with host classes, functions and closures.

- The interpreter is the single source of truth; JIT is a pure accelerator (see §5 for fallbacks).
- All three engines must agree **bit-for-bit** on result / error code / site / report text (I7).
- Native code is supported **only on Linux x86_64 and Linux aarch64**; other platforms run the
  interpreter (see §4).

---

## 1. Quick start

```cangjie
import fountain::f_jit.*

main() {
    let c = Compiler()                                   // same as Compiler(CompileOptions(DummyDiagnosticsSink()))
    // to collect diagnostics: Compiler(CompileOptions(MySink()))
    c.registerType<User>()                              // expose a host class to the dialect
    let f = c.compile('{ u: User => u.name }')          // compile (result cached in CompileCache)
    let name = f.call<String>([User('bob', 1)])         // call it
    println(name)                                       // bob
}
```

Interruptible call with a deadline:

```cangjie
let ctx = CallContext(deadline: Some(DateTime.now() + Duration.second * 1))   // throws InterruptedException
let v = f.call<Int64>([Int64(100_000_000)], ctx)
```

Returning a closure (escaping closure — must be `close()`d):

```cangjie
let f = c.compile('{ n: Int64 => let xs = [n, n + 1]\n { i: Int64 => xs[i] } }')
let g = f.callForFn<(Int64) -> Int64>([Int64(7)])
println(g.call<Int64>([Int64(1)]))    // 8
g.close()                          // release the promoted slots this closure captured
```

When the unit itself is no longer needed, call `close()`: it enters the terminal state, releases code
memory, and evicts the unit from the compile cache (recompiling the same source yields a new unit):

```cangjie
f.close()                            // unit-level; later calls on f throw JitException(ErrCode.CALL_CONTRACT)
```

A bare `close()` does **not wait** for in-flight calls: if any are still active it returns `false`
immediately and the unit goes back to usable. Pass `close(timeoutMs)` to drain.

---

## 2. API


| Type                                                                    | Purpose                                                         | Key members                                                                                                                                                            |
| ----------------------------------------------------------------------- | --------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Compiler`                                                              | Facade: register host capabilities + compile                    | `registerType<T>()`, **`registerInterface<I>()`**, `registerClass(desc)`, `registerFunction(f)`, `compile(src)`                                                        |
| `CompileOptions`                                                        | Compile options                                                 | `jit: JitMode` (`Auto`/`Force`/`Off`), `strictFp` (default `true`), `verMajor`, `cpuFeatures`, `diagnostics`                                                           |
| `JitFunction`                                                           | Compiled unit / callable object (implements`std.core.Resource`) | `call<T>(args)`, `call<T>(args, ctx)`, `callForFn<Fn>(args)`, `close()` / `close(timeoutMs): Bool` (entry = unload unit; wrapper = release this closure), `isClosed()` |
| `JitException`                                                          | Runtime failure (`base` package)                                | `code` (`ErrCode`), `site` (line:column / byte offset), `report`                                                                                                       |
| `CompileCache`                                                          | Compile cache (key includes`strictFp`/`verMajor`)               | `lookup`, `reset`, `runs`                                                                                                                                              |
| `CallContext`                                                           | Call context                                                    | `deadline` (interrupts at safety points → `InterruptedException`)                                                                                                     |
| `PredefinedFunction` / `ClassDescriptor` / `PublicCtor` / `PublicField` | Host registration surface                                       | Functions/classes/ctors/fields callable from the dialect                                                                                                               |
| `DbgDump`                                                               | Variable dump on failure (name/value/type)                      | Triggered by the diagnostics sink                                                                                                                                      |
| `JitReport`                                                             | Execution report (incl.`-1` DEOPT semantics)                    | Consumed by the bridge inside`call`                                                                                                                                    |

Packages (`fountain::f_jit.*`): `base` (contracts, error codes), `bytecode` (`.fbc` encode/decode/load),
`compiler` (front-end + lowering), `runtime` (interpreter, handle table, helpers), `backend` (two native
backends), `test.diff` (three-engine differential tests only).

---

### 2.1 Host-side macros: `@JitBind`, `@IgnoreJitBinding` and `@JitSignatures`

All three macros turn runtime reflection calls into static, strongly typed calls **at host compile time**:
`@JitBind` expands **class/interface members**, `@IgnoreJitBinding` opts a single member **out** of
registration, and `@JitSignatures` registers **closure parameter** signatures. Semantics are unchanged —
only the implementation of the registered bindings (performance) differs.

#### `@JitBind`: expand public members of a class/interface into typed bindings

```cangjie
import fountain::f_jit.*
import fountain::f_jit.macros.*

@JitBind
public class User {
    public var name: String
    public init(name: String) { this.name = name }
    public func greet(s: String): String { "hi ${s}" }
}

main() {
    let c = Compiler()
    c.registerType<User>()                    // no explicit bindings needed: registered at package init
    let f = c.compile('{ u: User => u.greet(u.name) }')
    println(f.call<String>([User('bob')]))    // hi bob
}
```


| Aspect       | Rule                                                                                                                                                                                                                                                                                          |
| ------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Expansion    | the class stays**unchanged**; one package-level `let jitBindEnroll_<Class> = enrollOf<Class>(JitBindings(...))` is generated — no declarations injected, no thunks                                                                                                                           |
| Covered      | instance methods →`PublicMethod`; instance fields (`var`/`let`) → getter (`var` also setter); properties (`prop`/`mut prop`) → getter + `set<Name>`; each `init` → one `PublicCtor`; **static functions / read-only static fields / read-only static properties** → `PredefinedFunction` |
| Not covered  | private members, generic methods (WARNING),`static var` and `static mut prop` (permanently excluded, WARNING), members marked `@IgnoreJitBinding`                                                                                                                                             |
| Registration | `Compiler.registerType<T>()` / `registerInterface<I>()` pick up the macro's registration when `bindings` is omitted                                                                                                                                                                           |

**Interfaces must be annotated**: reflection cannot `apply` abstract methods, so an unannotated interface
makes `registerInterface<I>()` raise `RegistrationException`. Parent-interface methods are merged at
registration time, so **a sub-interface-typed variable can call parent-interface members**:

```cangjie
@JitBind public interface Named { func name(): String }
@JitBind public interface Greeter <: Named { func greet(): String }

@JitBind
public class Impl <: Greeter {
    public func name(): String { "n" }
    public func greet(): String { "g" }
}

let c = Compiler()
c.registerInterface<Named>()
c.registerInterface<Greeter>()
c.registerType<Impl>()
c.compile('{ g: Greeter => g.name() }')      // parent-interface member, called natively
```

**Member-level opt-out**: `@IgnoreJitBinding`. The member stays **unchanged** in the class body (the host
can still call it) but is not registered — the dialect cannot see it; ignores are by name, so **all
overloads of that name are skipped**:

```cangjie
@JitBind
public class User {
    public var name: String
    @IgnoreJitBinding public var secret: String         // host-only, invisible to scripts
    @IgnoreJitBinding public func hostOnly(): Unit {}   // same
}
```

It is only valid inside a class/interface directly annotated with `@JitBind`; anywhere else
`assertParentContext` reports a compile error.

#### `@JitSignatures`: register closure parameter signatures

```cangjie
import fountain::f_jit.JitHost              // generated code uses the short name JitHost
import fountain::f_jit.macros.*

@JitSignatures[(Int64) -> Int64, (String) -> Bool]
public func jitSignatures(): Unit {}        // the function itself is untouched; signatures are registered at package init
```

- Expansion = one package-level `let __jitSig_<func>_<n>` per signature; at run time a table lookup by
  signature is used instead of `FunctionTypeInfo.apply`;
- **Boundaries**: flat signatures only (each parameter/return is a single type name; `()` allowed); a
  `14` position must be a **registered class name**; unregistered signatures keep the reflection path
  (same behaviour, just slower).

> All three macros are **host-side only**; dialect source (jit lambda) never contains macros.

### 2.2 The three registration entries: `registerType` / `registerInterface` / `registerClass`


| Entry                    | For                                            | Constraint                          | Binding source                                                                                                                                        | Guidance                                                                        |
| ------------------------ | ---------------------------------------------- | ----------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| `registerType<T>()`      | **classes**                                    | `where T <: Object`                 | `@JitBind`'s package-init registration (optional `bindings` **merge** and override individual members); without the macro it falls back to reflection | **Preferred**: annotate the class with `@JitBind`, register with no arguments   |
| `registerInterface<I>()` | **interfaces**                                 | **no** `T <: Object` constraint     | **requires** `@JitBind` (reflection cannot `apply` abstract methods)                                                                                  | Always annotate interfaces; parent-interface methods are merged at registration |
| `registerClass(desc)`    | any class (including ones you cannot annotate) | must supply a full`ClassDescriptor` | hand-written`PublicField` / `PublicMethod` / `PublicCtor`                                                                                             | only when macros/reflection are not an option                                   |

#### `registerType<T>()` — reflection-based auto registration (best with `@JitBind`)

```cangjie
@JitBind
public class User {
    public var name: String
    public init(n: String) { this.name = n }
}

let c = Compiler()
c.registerType<User>()          // picks up the @JitBind registration
```

- reflection collects the **ancestry chain**, used for static subtype checks (the `as` legality test);
- `bindings:` **merges** on top of the macro registration (same member: explicit wins), it never replaces it;
- **without `@JitBind`** members fall back to reflection: slower, and reference-typed members are subject to
  the "reject by default" policy ⇒ annotate in production.

#### `registerInterface<I>()` — interface registration (no `Object` constraint)

```cangjie
@JitBind public interface Named { func name(): String }
@JitBind public interface Greeter <: Named { func greet(): String }

let c = Compiler()
c.registerInterface<Named>()
c.registerInterface<Greeter>()          // parent-interface members are available: { g: Greeter => g.name() }
```

- **an unannotated interface raises `RegistrationException`** (abstract methods cannot be invoked reflectively);
- interfaces have no instance fields/constructors — the front end diagnoses accordingly.

#### `registerClass(desc)` — fully manual (no reflection)

```cangjie
import fountain::f_jit.base.{
    ClassDescriptor, LocalType, PredefinedFunction, PublicCtor, PublicField, PublicMethod
}

let greetFn = PredefinedFunction(
    name: 'greet',
    paramTypes: [LocalType.HOST_OBJECT],       // first param must be 14 (this class)
    retType: LocalType.STRING,
    impl: { a => 'hi' })

let desc = ClassDescriptor(
    name: 'LegacyUser',
    fields: [PublicField(name: 'name', `type`: LocalType.STRING, index: 0, mutable: true,
                         typeRef: None)],
    methods: [PublicMethod(name: 'greet', bind: greetFn)],
    ctors: [PublicCtor(params: [LocalType.STRING],
                       adapter: { a => LegacyUser(a[0] as String) })],
    parents: [])                                       // empty ⇒ same-type-only
c.registerClass(desc)
```

- a method's `bind` also joins the **predefined function surface** (`u.m()`'s hid source); an existing name is reused;
- manual registration does **no reflection at all**: field indices, method bindings and ctor adapters are your
  responsibility (a bad index/type code fails at construction time with `JitCallContract`);
- `parents` only affects **static subtype checks**; the front end never resolves members through it; empty ⇒ the
  class is only compatible with itself;
- name clashes (registered class / function name / builtin / keyword) ⇒ `RegistrationException`, nothing is registered.

## 3. How it works

**① Compile**: lexer/parser → AST → type checking → **stack bytecode** (157 opcodes, see
`doc/jit-bytecode-m1.md` §5). The `.fbc` container holds a header (`magic/verMajor/verMinor/crc32`…),
code section, constants, type tables, site table, function directory and a variable-name section.
Bytecode is **architecture-neutral**.

**② Execute (three engines)**:


| Engine           | Implementation             | Notes                                                   |
| ---------------- | -------------------------- | ------------------------------------------------------- |
| `Interp`         | Pure Cangjie interpreter   | Reference semantics; fallback on every platform         |
| `BackendX86_64`  | `X86Lower` → machine code | Linux x86_64; three passes (probe → CFG depth → emit) |
| `BackendAArch64` | `A64Lower` → machine code | Linux aarch64; dedicated operand-stack pointer`x20`     |

**③ Object model (handles)**: machine code never holds object pointers — only **Int64 handles** encoded as
`idx:u32 | tag:u16 | gen:u16` (`runtime/HandleTable.cj`). Objects live in a Cangjie `ArrayList<Any>` on the
managed heap; every access re-reads through a helper.

**④ Helpers and ABI**: machine code may only call a **closed whitelist** of helpers (H01–H83,
`runtime/HelperId.cj`) through the `@C` entry `h_dispatch(hid, ctx, args, argc)`. `ctx` is an 8×Int64
unmanaged block (`errCode/site/hwBase/hwCap/hwTop/fnId/flags/dbgBase`). There is no path for machine code
to call arbitrary Cangjie APIs.

**⑤ Window and escaping**: each `call` opens a handle window (`openWindow`); on return `resetWindow`
releases every **non-escaping** slot. Escaped objects (returned handles, escaping closures and their
captures) are promoted in place (`moveOutGroup`, same ID/gen) and owned by a `PromotionGroup` whose only
release path is `JitFunction.close()`; a unit-level `close()` that reaches the terminal state also
evicts the unit from the compile cache.

**⑥ Fail-and-fallback (deopt)**: `errCode = -1` means "replay this call in the interpreter"; the bridge
does that transparently. Any other code (1/2/3/6/7/8/16/18/19/21/22…) surfaces as `JitException`.

---

## 4. Support matrix (bytecode vs native code)


| Layer                                       | Supported                                                                                                      | Evidence                                                                                                                                          |
| ------------------------------------------- | -------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Bytecode** (compile / interpret / `call`) | **Any platform that runs Cangjie 1.3.x** (Linux / Windows / macOS, x86_64 / aarch64); architecture-independent | `.fbc` is plain data; `Interp` is pure Cangjie                                                                                                    |
| **Native code (JIT)**                       | **Linux x86_64 only**, **Linux aarch64 only**                                                                  | `backend/JitExecutor.cj`: requires `OS.current.isLinux` and `Arch.current ∈ {X86_64, AArch64}`; otherwise the whole unit runs in the interpreter |
| x86_64 prerequisite                         | **SSE4.1** (for `roundsd`-style rounding); without it, units containing rounding ops are not JITed             | `X86Lower.floatRoundChecked` / `CpuFeatures.hasSse41`                                                                                             |
| aarch64 prerequisite                        | None (no CPUID branch)                                                                                         | —                                                                                                                                                |

> Bottom line: **the same `.fbc` runs on all four platforms**; **Linux x86_64 / Linux aarch64 execute
> native code**, Windows / macOS execute the interpreter (different speed, identical semantics).

---

## 5. When JIT is skipped (by design)

JIT is an accelerator; on any of the following, the **whole unit** falls back to the interpreter
(`ok = false`) — semantics unchanged, only slower:


| Category                   | Examples                                                                                                               |
| -------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| Rejected at assembly time  | `DT_NEW` (0xA9), `DUR_NEW` (0xAA)                                                                                      |
| Missing runtime facilities | needs a constant mirror but`constBase == 0`; needs a function table but `fnTableBase == 0`                             |
| Platform capability        | x86 without SSE4.1 and the unit contains rounding ops                                                                  |
| Statically unprovable      | inconsistent operand-stack depth at a merge; emit audit finds an out-of-set memory base (only stack/frame/ctx allowed) |
| Unimplemented              | unknown opcode (anything not yet lowered falls back)                                                                   |

---

## 6. Data types and syntax

The dialect is a **subset of Cangjie**: every type maps to the Cangjie standard library (no
user-defined types). Literals and operators:


| Type         | Backing (std)                       | Literals / construction                                                                                    | Main operations                                                                                                                      |
| ------------ | ----------------------------------- | ---------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| **Int64**    | scalar                              | `42`, `-7`                                                                                                 | `+ - * / % **`, comparisons; `/` and `%` by zero → 3; `Int64(x)` narrowing                                                          |
| **Float64**  | scalar                              | `1.5`, `1.0f64`, `1.5e3f64`, `.123e2f64`                                                                   | `+ - * /`, comparisons; `strictFp` defaults to `true` ⇒ ÷0 fails with 1, otherwise IEEE ±Inf                                      |
| **String**   | `std.core.String`                   | `'abc'` / `"abc"`, multi-line `'''…'''` / `"""…"""`, raw `#`×n; interpolation `"v${x}"`                 | `+` concat, `* 3` repeat, `s[a..=b]` (code-point half-open range)                                                                    |
| **Range**    | `std.core.Range`                    | `a..b`, `a..=b`, optional `: step`                                                                         | `for x in a..b { … }`                                                                                                               |
| **List**     | `std.collection.ArrayList`          | `[1, 2, 3]` (**constant, shared read-only**), `[]` (fresh **mutable** empty list, needs a contextual type) | `xs[i]`, `xs[i] = v`, `for x in xs`; append/remove are mutating helpers (`LIST_APPEND`/`LIST_REMOVE`; writing a constant → 20)      |
| **Map**      | `std.collection.HashMap`            | `{k: v}` (constant, read-only), `{}` (mutable, needs a contextual type)                                    | `m[k]`, `m[k] = v`, `for (k, v) in m`                                                                                                |
| **JSON**     | handles 16–19 (`JsonValue` family) | **backtick literal**: `` `{"k": 1}` `` (the only form; parsed once at load time)                           | `j["k"]` read, `j["k"] = v` write (mutable in-world), member sugar `j.k`, `is`/`as`; `JsonObject(...)` construction → compile error |
| **Regex**    | `std.regex.Regex`                   | `/pat/flags` (flags ∈ `i m u`, order-independent, idempotent); `s.regex()` builds at run time (no flags)  | `re ~ s`, `re !~ s`, `re/s/r/g` (replace all), `re/s/r/n` (replace n times)                                                          |
| **Decimal**  | `std.math.numeric.Decimal`          | **a bare decimal literal is a Decimal**: `1.23`, `1.5e3`, `1e-3`; `Decimal(...)`                           | `+ - * /`, comparisons                                                                                                               |
| **Duration** | `std.core.Duration`                 | no literal (from the host, or`DateTime` difference)                                                        | `Duration ± Duration`, comparisons; overflow → 12                                                                                  |
| **DateTime** | `std.time.DateTime`                 | no literal (from the host)                                                                                 | `DateTime ± Duration`, `DateTime − DateTime → Duration`; out of range → 11                                                       |
| **Closure**  | handle 12 (`JitClosure`)            | `{ x => e }`, captures outer locals                                                                        | call`f(a)`; escaping returns use `callForFn<Fn>`, then `close()`                                                                     |
| **Any**      | handle 12 (`JitAnyBox`)             | passed in by the host, or`Any`-annotated local/param                                                       | boxing/unboxing (H78/H79),`is` checks, returned as `Any`                                                                             |

```cangjie
// one literal per type (as a jit lambda's return / local)
c.compile('{ => 42 }')                       // Int64
c.compile('{ => 1.5 }')                      // Float64
c.compile('{ => 1.23 }')                     // Decimal (bare decimal literal)
c.compile('{ x: Int64 => "v${x}" }')         // String (interpolation)
c.compile('{ => /^[a-z]+$/i }')              // Regex
c.compile('{ => [1, 2, 3] }')                // List (constant, read-only)
c.compile('{ => { "a": 1 } }')               // Map (constant, read-only)
c.compile('{ => 1..=5 }')                    // Range
```

**Read-only constants vs mutable containers**: non-empty literals are built once at assembly time and
shared across calls — writing them fails with `ERR_READONLY(20)`; `[]`/`{}` build a fresh mutable
container on every evaluation (not in the constant table) and need a contextual type (annotation or
parameter signature).

### 6.0 Regex literals and the `i` / `m` / `u` flags

Literal form `/pattern/flags`: `pattern` (UTF-8) sits between the two `/`, and the following `i`/`m`/`u`
characters are flags.


| flag      | Meaning                                                                     | Effect                                                                                                                                                                        | Example (result)                                                         |
| --------- | --------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------ |
| `i`       | **Case-insensitive** (`RegexFlag.IgnoreCase`; `std.regex` is authoritative) | case-folds literal characters and character classes; escape sequences themselves are unaffected                                                                               | `/AbC/i ~ "abc"` → `1`; `/AbC/ ~ "abc"` → `0`                          |
| `m`       | **Multiline**                                                               | `^` also matches right after every newline, `$` also matches right before every newline. It does **not** make `.` match newlines (no DOTALL/`s` flag)                         | `/^b/m ~ "a\nb"` → `1`; `/^b/ ~ "a\nb"` → `0`; `/c$/m ~ "c\nd"` → `1` |
| `u`       | **Unicode mode**                                                            | character classes/`\p{…}` match **code points** (one element = one code point, not one byte); `\w`/`\d` use Unicode ranges (`std.regex` is authoritative)                    | `/^\p{L}+$/u ~ "中文"` → `1`                                            |
| combining | `i m u` in **any order, repeats idempotent**                                | normalised to a bitfield at load time (bit0=i bit1=m bit2=u); order/repeats never affect the dedup key, text form or matching behaviour (`/pat/im` ≡ `/pat/mi` ≡ `/pat/ii`) | —                                                                       |
| illegal   | any character other than`i m u`                                             | **rejected at load time** (`JitException(14)`, `site=-1`, never executed)                                                                                                     | `/pat/x` → 14                                                           |

Notes:

- an **illegal or empty pattern** is also rejected at load time with 14 (an empty pattern would cause a
  zero-width loop, §11.9);
- the literal is compiled **once at load time** and reused across calls (constant kind 10, deduped by
  `(pattern, flags)`, same handle ID);
- building a regex from a string at run time uses `s.regex()` (the `fountain::f_regex` extension), which
  has **no flags**; use the literal form when flags are needed;
- operators: `re ~ s` (match), `re !~ s` (negated), `re/s/r/g` (replace all), `re/s/r/n` (replace n times).

### 6.1 Multi-line strings and the line-anchor marker `>|`

Multi-line strings use `'''…'''` / `"""…"""` (raw `#`×n strings are separate). When **source
indentation** conflicts with **content indentation** (typically JSON embedded in a string), use the
line-anchor marker `>|`: the marker plus its leading indentation is consumed, and the rest of the line is
the content.

```text
"""{
>|  "k": 1,
>|  "n": [2, 3]
>|}"""
```


| Rule             | Detail                                                                                                                                                                                 |
| ---------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Scope            | **Multi-line forms only** (`'''` / `"""`); single-line and raw (`#`×n) strings are unaffected (`>|` is just two characters there)                                                     |
| Valid marker     | the`>|` at the **first non-blank position** of a line (only indentation may precede it)                                                                                                |
| Mode switch      | if**any** line has a valid marker, the **whole string** is in anchor mode; otherwise normal mode (`a>|b` does not trigger)                                                             |
| Marker line      | the marker and its leading indentation are consumed; everything**after** `>|` is the line content (further `>|` on that line is literal text; a bare `>|` line yields an empty string) |
| Non-marker line  | kept**verbatim** (no slicing, no normalisation)                                                                                                                                        |
| First-only       | `>|>|abc` → `>|abc`; `>|    >|` → `    >|` (only the first valid marker is consumed)                                                                                                 |
| Joining          | lines are joined with`\n` (`CRLF`/`CR` normalised to `\n` for the whole string first)                                                                                                  |
| Order            | anchoring happens**before** escape decoding and before interpolation splitting: `${x}` in `>|${x}` still interpolates, the `>|` never enters the text                                  |
| Non-marker cases | `>>|`, `a>|b`, `|>|` ⇒ `>|` is literal content (line kept as-is)                                                                                                                      |

> Note: `>|` is **not** a global dedent — only lines with a valid marker are sliced; all other lines are
> preserved verbatim.

### 6.2 Recursion (`recursive`)

Self-recursion uses the keyword `recursive(...)` (not the function name):

```cangjie
let fact = c.compile('{ n: Int64 => if (n <= 1) { 1 } else { n * recursive(n - 1) } }')
fact.call<Int64>([Int64(5)])      // 120
```

Lowering differs by position:


| Position          | Lowering                                                                                                                          |
| ----------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| Top-level lambda  | `CALL_FUNC <entryFn>` (through the **function table**, host absolute address)                                                     |
| Inside a closure  | `LOADL 0` (`locals[0]` holds the closure itself) + `CALL_CLOSURE`                                                                 |
| **Tail position** | arguments in**reverse order** into `STOREL` + `LOOP_BACK <entry>` (frame reuse, no `RET`; tail recursion does not grow the stack) |

### 6.3 Nested closures and recursive nested closures

```cangjie
// nested closure: captures outer locals; the inner `recursive` refers to itself
let f = c.compile('{ n: Int64 =>
    let inner = { k: Int64 => if (k <= 1) { 1 } else { k * recursive(k - 1) } }
    inner(n)
}')
f.call<Int64>([Int64(4)])         // 24
```

- Captures are classified by origin (`CaptureOrigin`); handle-typed captures are **promoted in place**
  together with an escaping closure;
- The inner `recursive` is that closure itself (`LOADL 0` + `CALL_CLOSURE`), not the outer `entryFn`;
- Nesting is unbounded (each level is a `LOAD_CAP` chain, one closure object per level);
- **Escaping** a closure: take the wrapper via `callForFn<Fn>` and `close()` it when done (otherwise its
  promotion group stays resident).


Besides being a call target, `recursive` can also be used as an **rvalue** (a value-ised self reference) —
treating "itself" as a closure value:

```cangjie
// bind the current closure to a local, then let an inner closure capture it
let f = c.compile('{ n: Int64 =>
    let outer = recursive                       // outer *is* the current closure (same handle)
    let inner = { m: Int64 => if (m <= 0) { 0 } else { outer(m - 1) } }
    if (n <= 0) { 0 } else { inner(n - 1) }
}')
f.call<Int64>([Int64(3)])         // 0
```


| Position                  | Rvalue lowering                                                                                                  |
| ------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| Inside a closure          | `LOADL 0` → `CLOSURE` (creates **no** new closure object; same handle as the enclosing closure)                 |
| Top level (not a closure) | a synthetic adapter closure that forwards to`entryFn`, so the host still gets a closure value pointing at itself |

- The value can be stored in a local, passed as an argument, or captured by an inner closure (capture type 12;
  promoted with the promotion group when the closure escapes);
- **Caveat**: `outer` and the current closure are the **same** closure — once `{ => outer() }` is called it is
  unbounded self-recursion (when used as an alias or as an inner indirection it must carry its own
  termination condition).

### 6.4 `as` syntax (cast / fallback / test)


| Form           | Semantics                                                                                                   | Failure behaviour                                                                                                                                |
| -------------- | ----------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| `x as T`       | downcast;`T` must be compatible with the static type of `x`                                                 | incompatible →**rejected at compile time** (message names both types); runtime mismatch → **7 `BAD_CAST`** (not reported as host exception 21) |
| `x as T ?? fb` | "take the original object on success, otherwise`fb`"; **the fallback is lazy** (never evaluated on success) | mismatch is not an error;`fb` must be `T` or a subtype of `T`                                                                                    |
| `x is T`       | type test returning`Bool` (no cast, no error)                                                               | —                                                                                                                                               |

```cangjie
let pick = c.compile('{ u: User => u as Admin ?? Admin("fallback") }')
// Admin instance → the object itself; User instance → the fallback value
```

Additional rules:

- **Untracked class names** (e.g. a 14-returning call without `retName`) ⇒ compiles, decided at **run time**
  via `$as$<T>`;
- `??` is legal **only** as `as T ??`; `x ?? 0` and `x ? 0` are syntax/lexical errors;
- the fallback expression is still lowered (an undefined name inside it is a compile error;
  `x as Int64 ?? (x / 0)` returns `x` on success and never evaluates the fallback);
- `Any` uses the Any channel (box 12 → object handle on success; on failure `as` yields 22, bare `as` → 7).

### 6.5 ⚠ `JitFunction` cannot be a parameter of a jit lambda

`JitFunction` is a **bridge-side executable** (code buffer, constant mirror, function table, promotion
group) — not a dialect value type. `Compiler.registerType()` only accepts host types that map to a
`LocalType`, and `JitFunction` has no code, so it cannot appear in a lambda's parameter or return type
(rejected at compile time).

To "pass a JIT function into a lambda", **wrap it in a closure** and pass the host closure
(`HOST_CLOSURE`, code 13):

```cangjie
let inc = c.compile('{ x: Int64 => x + 1 }')

// ✓ capture the JitFunction in a host closure; what crosses the bridge is a closure, not the JitFunction
let bridge: (Int64) -> Int64 = { n => inc.call<Int64>([n]) }

// the lambda declares the parameter as a host closure; the next line is schematic
// (the type name follows the host-closure signature registered on the Compiler)
let apply = c.compile('{ f: Fn, n: Int64 => f(n) }')
apply.call<Int64>([bridge, Int64(41)])     // 42
```

Key point: the `JitFunction` stays on the **host side**; only the closure value crosses the bridge. If
the closure escapes the call, the host must keep the captured `JitFunction` alive (make its lifetime
longer than the closure's).

### 6.6 Exponentiation `**` and scientific notation


| Item                       | Rule                                                                                                                                         |
| -------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| `**` types                 | `(Int64, Int64) → Int64` only; anything else (`1.5 ** 2`, `2 ** 1.5`, `"a" ** 2`) is a compile-time `TYPE_MISMATCH`                         |
| Precedence / associativity | **4** (tighter than `*`/`/`/`%`, looser than unary `-`), **right-associative**: `2 ** 3 ** 2` = 512; `-2 ** 2` = 4                           |
| Exponent                   | must be**non-negative** (Cangjie uses `UInt64`, so a negative exponent is unrepresentable): a runtime negative → `ERR_ARG_MISMATCH(14)`     |
| Overflow                   | `ERR_OVERFLOW_I64(3)` (`2 ** 63` fails); `x ** 0` = `1`, `0 ** 0` = `1`, `0 ** n` = `0`                                                      |
| Implementation             | shared helper**H84 `ipow`** (fast power, O(log n)); identical in all three engines ⇒ bit-identical results/error codes, zero backend change |
| Scientific (Decimal)       | `1.5e3` (=1500), `3e2` (=300), `1e-3` (=0.001), `2.4E-1`                                                                                     |
| Scientific (Float64)       | `1.5e3f64`, `2e3f64`, `2.4e-1f64`, `.123e2f64` (= 12.3)                                                                                      |
| Leading dot                | `.5`, `.5e2` (Decimal), `.5e2f64` (Float64) are all valid                                                                                    |
| Illegal                    | `1e`, `1e+`, identifier right after a number, `1.5f32` (no `f32` in the dialect) → lexical error                                            |

```cangjie
c.compile('{ => 2 ** 10 }')                 // 1024
c.compile('{ => 2 ** 3 ** 2 }')             // 512 (right-associative)
c.compile('{ => 2 * 3 ** 2 }')              // 18 (** binds tighter)
c.compile('{ x: Int64 => 2 ** x }')         // negative x → 14; overflow → 3
c.compile('{ => 1.5e3 }')                   // Decimal 1500
c.compile('{ => .123e2f64 }')               // Float64 12.3
```

## 7. FAQ

### Q1 Who owns objects created on the JIT side — the JIT or Cangjie?

**Cangjie.** Machine code only holds `Int64` handles; object bodies live in
`HandleTable.objs: ArrayList<Any>` on the managed heap. Allocation always goes through
`allocValue` → `HandleTable.append` (`runtime/HelperCore.cj:77-83`):

```cangjie
public static func append(ctx: JitContext, obj: Any, tok: UInt16): Int64   // runtime/HandleTable.cj:486
```

Custom class instances (tag 14), `String`(4), `Decimal`(6), `Range`(7), `Duration`(8), `JitRegex`(9),
`List`(10), `Map`(11), `JitAnyBox`(12), `JitClosure`(12/13) and JSON nodes (16–19) all live in that table.

### Q2 The GC moves objects. How can machine code still access them?

**Machine code never dereferences object pointers.** Handles are indices; every access re-reads the
current reference on the Cangjie side (`runtime/HandleTable.cj:567`):

```cangjie
public static func getAny(id: Int64): ?Any {
    ...
    } else if (!alive[i] || gens[i] != genOf(id)) { None }
    else { Some(objs[i]) }
```

When the GC moves an object it updates `objs[i]` and managed locals in helper frames (stack maps); the
`Int64` in machine code is untouched. `pin`/`pinHostObject` references are used **within a single helper
call** only — never across helpers, never written back to machine code. Constant mirrors and function
tables store **cells and code addresses**, not object pointers.

### Q3 After a call returns, do objects stay resident? Any leak?


| Case                             | Handling                                                                                                           | Resident?                                                                                      |
| -------------------------------- | ------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------- |
| Non-escaping (inside the window) | `call`'s `finally` → `resetWindow(-1)`: `alive=false`, `objs[i]=0`, `gen+1`                                       | No longer referenced by f_jit ⇒ collected by GC                                               |
| Returned handle                  | `releaseReturnHandle` releases it right after unboxing (`JitFunction.cj:477-487`)                                  | No                                                                                             |
| Escaping closures / captures     | Owned by`PromotionGroup`; **released by the wrapper's `close()`, with unit `close()` cascading at terminal state** | Stays resident until the host releases it, for as long as the unit lives (contract, not a bug) |

Constant slots (`constFlags`) are never released (unit constant pool, bounded); the underlying
`HandleTable` arrays only grow, capped by `capacityLimit = 1048576` (`:92`) — a watermark, not a leak.

### Q4 Do non-escaping nested closures (and their captured data) die with `JitFunction`?

**They die with the call, not with `JitFunction`.** A closure is a `JitClosure(fnId, captured: Array<Int64>)`
created by H54 (`runtime/Helpers.cj:1010-1021`) inside the call window; captures are **cells (handles)** to
slots in the same window. `resetWindow` releases them all at return time (IDs invalidated via `gen+1`), and
the `JitClosure` object is collected afterwards. `JitFunction` only holds compiled artifacts; `close()`
releases just the promotion group.

### Q5 Does every call clean up what it produced?

**Yes — all four exits (normal / error / interrupt / DEOPT replay) converge in one `finally`**
(`JitFunction.cj:454-467`):

```cangjie
} finally {
    if (helpers.size > 0) { UserHelperTable.pop() }
    marshal.cleanup()          // pinned, non-escaping slots
    IterTable.clearAll()       // iterator cursors
    HandleTable.resetWindow(-1)
    if (!dump.isNull()) { DbgDump.freeDump(dump) }
    JitContext.free(ctx)
}
```

Re-entrancy is safe: `openWindow` pushes the outer window and `resetWindow` pops it back, so host-closure
callbacks do not wipe outer slots.

### Q6 How does an escaping closure keep accessing the data it captured?

**In-place promotion plus a promotion group.** When a closure is returned, `CallMarshal.unboxClosure`
recursively promotes the closure slot and all handle-typed captures (`CallMarshal.cj:216-269`):

- `group.add(id)` → `HandleTable.moveOutGroup`: sets `escapeFlags=true`, removes it from window accounting,
  **keeps ID/gen unchanged** ⇒ `resetWindow` skips it and the slot is never reused;
- the wrapper `JitFunction` holds `owner + closureId + group`; invoking it goes through
  `owner.invokeClosure` and reads captures via `closure_cap(h,i)`;
- release: `close()` → `PromotionGroup.releaseAll()` → `releaseEscaped`.

Container captures are **slot-level, no cascade** (§14.6): element handles need no promotion because
elements are converted to host references on write (`cellToAny` = `getAny`) and live as long as the
container.

---

## 8. Known limitations

- Native code only on Linux x86_64 / aarch64 (all other platforms interpret);
- x86_64 requires SSE4.1 (units with rounding ops are not JITed otherwise);
- one H22 `interrupt_poll` per loop back-edge; on tight loops this call (which allocates) is costly —
  tracked in `doc/spec/f-jit-m1/verify.md`;
- escaping closures should be `close()`ed explicitly; skipping it is recovered by the cascading unit `close()`, but a long-lived unit keeps the promotion group resident;
- specifications: `doc/jit-bytecode-m1.md` / `doc/design-m1.md` / `doc/plan-m1.md`; acceptance:
  `doc/spec/f-jit-m1/verify.md`; performance: `doc/perf-m1.md`.

---

## Other public API

The declarations below are not expanded above; they are grouped by module level and by type (members declared in `extend` blocks are listed under the extended type). See the corresponding files under `src/` for the full semantics.

- Module level: `A64Compiler` (class), `AArch64Runner` (class), `Backend` (interface), `BackendSelector` (class), `ByteReader` (class), `ByteWriter` (class), `CanonKey` (class), `CodeBuffer` (class), `CompileCacheKey` (class), `ConstKind` (class), `ConstMirror` (class), `ConstPayload` (enum), `ConstRegistry` (class), `CtorBad` (class), `CtxFlags` (class), `DecodedInsn` (struct), `DedupGuard` (class), `DiagCode` (enum), `DiagnosticLevel` (enum), `DiagnosticsSink` (interface), `DiffCase` (class), `DiffEngine` (enum), `DiffMismatchException` (class), `DiffOutcome` (class), `DiffRunner` (interface), `DiffSession` (class), `EscapeArea` (class), `FbcFlags` (class), `FbcHeader` (struct), `FbcReader` (class), `FbcRuleRegistry` (class), `FbcRuleSet` (class), `FbcWriter` (class), `Fingerprint` (class), `FnTable` (class), `FuncDir` (class), `FuncEntry` (struct), `FuncFlags` (class), `HelperAddresses` (class), `HelperFail` (class), `HostCallback` (class), `HostFault` (class), `HostFieldAccessor` (class), `HostFieldTable` (class), `HostSignature` (class), `InsnDecoder` (class), `InterpRunner` (class), `IterTable` (class), `JitArtifacts` (class), `JitBindSupport` (class), `JitClosureId` (struct), `JitCompiler` (class), `JitContext` (class), `JitFieldBinding` (class), `public class JsonArray {}`, `public class JsonNull {}`, `LoadedUnit` (class), `LocalTypes` (class), `MachineEnv` (class), `NameEntry` (struct), `NameTable` (class), `NativeAssets` (class), `NativeMem` (class), `public class NativeRunner <: DiffRunner`, `OpInfo` (struct), `ReflectAdmin` (class), `ReflectAnyHolder` (class), `ReflectBox` (class), `ReflectUser` (class), `RegistrationRejectKind` (enum), `RuntimeEnv` (class), `SignatureDescriptor` (class), `SignaturePlan` (class), `SignatureRegistry` (class), `SignatureTable` (class), `SignatureVerifier` (class), `SiteEntry` (struct), `SiteTable` (class), `SourceCompileException` (class), `SourcePos` (struct), `SourceUnit` (struct), `StubRunner` (class), `TCase` (class), `TMapping` (class), `T_MAP_IN_SCOPE` (let), `T_MAP_M2` (let), `T_MAP_M3` (let), `TextFormat` (class), `TypeNames` (class), `TypeToken` (class), `UserHelperEntry` (class), `UserHelperTable` (class), `Version` (class), `X86Compiler` (class), `abiSummary` (func), `addAutoFunction` (func), `addFunc` (func), `allTMappings` (func), `allocCtorHelper` (func), `allocSlot` (func), `analyze` (func), `assemble` (func), `assertTripleEqual` (func), `autoFunctions` (func), `awaitReady` (func), `bail` (func), `public let body: Array<AstStmt>`, `public let breakLabels: ArrayList<Int64>`, `buildCtor` (func), `public let builder: BytecodeBuilder`, `bytes` (func), `callClosure` (func), `callFunc` (func), `callHelper` (func), `callHelperNoCheck` (func), `callHelperVoid` (func), `callHost` (func), `captureDescriptors` (func), `public let captures: ArrayList<VarSym>`, `claim` (func), `classOf` (func), `public let classes: Array<ClassDescriptor>`, `closureFnId` (let), `closureGroupOf` (func), `public func closure_fnid(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64`, `public func closure_new(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64`, `codeLen` (func), `column` (func), `consts` (let), `constsOf` (func), `public let continueLabels: ArrayList<Int64>`, `ctorHelperList` (func), `ctorHelpers` (let), `ctorsOf` (func), `public func dec_add(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64`, `public func dec_div(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64`, `public func dec_from_f64(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64`, `public func dec_from_i64(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64`, `public func dec_mul(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64`, `public func dec_sub(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64`, `public func dec_to_f64(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64`, `public func dec_to_i64(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64`, `declare` (func), `depthNow` (func), `describe` (func), `diffFour` (func), `dir` (let), `display` (func), `public func dt_add(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64`, `public func dt_diff(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64`, `public func dt_sub(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64`, `dump` (func), `public func dur_add(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64`, `public func dur_div(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64`, `public func dur_mul(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64`, `public func dur_neg(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64`, `public func dur_sub(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64`, `elemCode` (func), `elemTy` (let), `emit` (func), `emitI32` (func), `emitI64` (func), `emitRel` (func), `emitU16` (func), `emitU16U8` (func), `emitU8` (func), `empty` (func), `public let entries: Array<CaptureEntry>`, `public let entryLabel: Int64`, `entryParamClasses` (let), `entryParamSigs` (let), `entryThunkBase` (func), `entryThunkFor` (func), `public func err_raise(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64`, `escapeAndGet` (func), `escapedIds` (func), `public let escaping: Bool`, `fail` (func), `failWith` (func), `failureOf` (func), `fieldOf` (func), `find` (func), `public let fingerprint: UInt64`, `finish` (func), `fixupRel` (func), `fnIdOf` (func), `public func fn_table(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64`, `funcAt` (func), `funcCount` (prop), `public func h_guard(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64`, `public func h_is_type(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64`, `public func h_nonnull(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64`, `public func h_ref_eq(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64`, `public func h_tag_of(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64`, `handleCaptureNames` (func), `has` (func), `hasFunction` (func), `hashCode` (func), `public func hd_cmp(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64`, `public func hd_is_int(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64`, `public func hdur_cmp(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64`, `public func hdur_ticks(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64`, `hex` (func), `hidOfSlot` (func), `public func hl_get(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64`, `public func hl_len(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64`, `public func hm_get(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64`, `public func hm_get_or(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64`, `public func hm_has(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64`, `public func hm_len(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64`, `hostParamNames` (func), `hostParams` (func), `hostRet` (func), `hostRetName` (func), `public func host_call_trampoline(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64`, `public func host_get_field(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64`, `public func host_set_field(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64`, `public func hs_at(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64`, `public func hs_cmp(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64`, `public func hs_len(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64`, `public func ht_cmp(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64`, `public func ht_field(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64`, `public func hw_check(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64`, `implOf` (func), `impls` (let), `invalidEntries` (func), `invokeHelper` (func), `isBuiltinName` (func), `isCallHelper` (func), `public let isClosure: Bool`, `isHostObjectCode` (func), `isInstanceOfClass` (func), `isInstanceOfHost` (func), `isInvalidIfEscapes` (func), `isKeywordName` (func), `isMutating` (func), `isRegistered` (func), `isSameOrSubclass` (func), `isTerminator` (func), `isUncondJump` (func), `isValueCode` (func), `public func jit_dump(dump: CPointer<Int64>, errCode: Int64, fnId: Int64, nLocals: Int64`, `keyCode` (func), `keyTy` (let), `kind` (let), `lastRegexFlags` (func), `line` (func), `public func list_add(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64`, `public func list_insert(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64`, `public func list_new(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64`, `public func list_remove(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64`, `public func list_set(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64`, `lowerTop` (func), `makeArgMarshalers` (func), `makeRetUnboxer` (func), `public static func mapToken(t: UInt16): UInt16`, `mapType` (func), `mapTypeRef` (func), `public func map_iter_begin(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64`, `public func map_iter_step(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64`, `public func map_new(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64`, `public func map_put(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64`, `public func map_remove(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64`, `marshalArg` (func), `marshalHostClosure` (func), `maxStack` (let), `maxStackSeen` (func), `methodOf` (func), `methodsOf` (func), `nLocals` (func), `names` (let), `public let nargs: Int64`, `needsAutoCheck` (func), `needsPromotion` (func), `newFnId` (func), `newLabel` (func), `next` (func), `nlBefore` (let), `noteFunction` (func), `objectName` (func), `of` (func), `okOutcome` (func), `ops` (func), `ordinal` (func), `public let origin: UInt8`, `public let paramNames: Array<String>`, `paramTypesOf` (func), `public let parent: ?FnCtx`, `parseBlockBody` (func), `parseExpr` (func), `parseLambda` (func), `parseMapLit` (func), `pendingSites` (func), `place` (func), `popScope` (func), `public let pos: SourcePos`, `position` (func), `pushScope` (func), `public func range_contains(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64`, `public func range_new(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64`, `public let raw: Array<UInt8>`, `public func regex_find(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64`, `public func regex_is_match(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64`, `public func regex_replace_all(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64`, `public func regex_replace_nth(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64`, `public func regex_replace_range(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64`, `register` (func), `registeredList` (func), `registry` (let), `public let relOff: Int64`, `remove` (func), `removeFunction` (func), `removeUnit` (func), `requireClass` (func), `requireCtors` (func), `requireField` (func), `requireMethod` (func), `requireValue` (func), `resetRetainedForTest` (func), `resolve` (func), `public let ret: UInt16`, `public let retExpr: ?AstExpr`, `retTypeOf` (func), `retTypes` (let), `retVoid` (func), `retainedCount` (func), `public static func runSource(source: String, c: Compiler): JitFunction`, `runUnit` (func), `public let scopes: ArrayList<ArrayList<VarSym>>`, `setSite` (func), `setSlotType` (func), `public let sites: Array<PendingSite>`, `public let slot: Int64`, `slotCount` (func), `slotOf` (func), `slotType` (func), `slotTypeTable` (func), `snapshot` (func), `snapshotOf` (func), `source` (let), `public func str_cat(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64`, `public func str_repeat(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64`, `public func str_replace(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64`, `public func str_sub(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64`, `public func str_to_regex(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64`, `text` (let), `throwJit` (func), `public func to_str(ctx: CPointer<Unit>, args: CPointer<Int64>, n: Int64): Int64`, `token` (let), `tokenize` (func), `public let ty: UInt16`, `public let typeAnn: TypeRef`, `public let typeCode: UInt16`, `public let types: LocalTypes`, `value` (let)
- `A64Compiler`: `compileFunction` (func), `compileFunctionFar` (func), `compileFunctionWith` (func)
- `AArch64Runner`: `func engine(): DiffEngine`, `isAvailable` (func), `run` (func)
- `ByteReader`: `bytes` (func), `f64bits` (func), `i32` (func), `i64` (func), `offset` (func), `remaining` (func), `seek` (func), `u64` (func), `u8` (func)
- `ByteWriter`: `take` (func), `wBytes` (func), `wI32` (func), `wI64` (func), `wU16` (func), `wU32` (func), `wU64` (func), `wU8` (func)
- `CanonKey`: `bitsAsI64` (func), `cell` (func), `dateTime` (func), `dec` (func), `decFromText` (func), `duration` (func), `f64` (func), `i64` (func), `range` (func), `str` (func)
- `ClassDescriptor`: `isInterface` (let)
- `CodeBuffer`: `alloc` (func), `flushCount` (func), `flushICache` (func), `pageSize` (func), `patch` (func), `rawPointer` (func), `read` (func), `resetFlushCount` (func), `seal` (func), `write` (func)
- `CompileCacheKey`: `arch` (let), `fingerprint` (let), `hashCode` (func)
- `Compiler`: `hasClass` (func), `hasFunction` (func), `let opts: CompileOptions`, `registeredNames` (func), `unregisterFunction` (func)
- `ConstMirror`: `at` (func), `build` (func)
- `ConstPayload`: `kindOf` (func)
- `ConstRegistry`: `addDateTime` (func), `addDecimal` (func), `addDuration` (func), `addF64` (func), `addI64` (func), `addJson` (func), `addList` (func), `addMap` (func), `addRange` (func), `addRegex` (func), `addStr` (func), `addValue` (func), `decode` (func), `encode` (func), `freeze` (func), `get` (func), `instanceAt` (func), `instantiateAll` (func), `isFrozen` (prop), `regexCompileCount` (var)
- `CtorBad`: `let value: Int32`
- `DbgDump`: `allocateDump` (func), `writeOnce` (func), `writeOnceStackRaw` (func)
- `DecodedInsn`: `op` (let), `operands` (let)
- `DedupGuard`: `fingerprint` (prop), `matches` (func), `rawBytes` (prop)
- `DiffCase`: `unit` (let)
- `DiffOutcome`: `result` (let)
- `DiffSession`: `assertTripleEqual` (func), `ran` (func), `runAll` (func), `skipped` (func), `skippedEngineNames` (func)
- `DummyDiagnosticsSink`: `func diag(level: DiagnosticLevel, code: DiagCode, message: String): Unit {}`
- `ErrCode`: `describe` (func), `isHostSide` (func)
- `EscapeArea`: `clear` (func), `contains` (func), `snapshot` (func)
- `FbcHeader`: `let codeLen: UInt32`, `let constLen: UInt32`, `hdrSize` (let), `isLegacyLayout` (func), `nameLen` (let), `payloadOff` (func), `read` (func), `let siteLen: UInt32`, `write` (func)
- `FbcReader`: `UNSUPPORTED_MINOR` (let), `load` (func), `loadWithoutRegistry` (func), `maxSupportedMinor` (let), `minVerMinorOf` (func), `rulesFor` (func), `supportedMajor` (let), `validate` (func)
- `FbcRuleRegistry`: `V1` (let), `V2` (let), `V3` (let), `get` (func)
- `FbcRuleSet`: `implemented` (let), `isInstructionLegal` (func), `isLocalTypeInLegalSet` (func), `isLocalTypeLegal` (func), `isRegistryDependent` (func), `isVerMinorSupported` (func), `maxLocalType` (let), `maxVerMinor` (let), `minVerMinor` (let)
- `FbcWriter`: `build` (func), `crc32OfPayload` (func), `setCode` (func), `setConst` (func), `setEntryFn` (func), `setFlags` (func), `setName` (func), `setSite` (func), `setVersion` (func)
- `Fingerprint`: `bytecodeKey` (func), `constFingerprint` (func), `fnv1a128` (func), `fnv1a64` (func), `normalizeSource` (func), `sourceKey` (func)
- `FnTable`: `alloc` (func)
- `FuncDir`: `at` (func), `find` (func), `get` (func), `validate` (func)
- `FuncEntry`: `codeLen` (let), `codeOff` (let), `localTypesOff` (let), `maxStack` (let), `nLocals` (let), `nargs` (let), `read` (func), `write` (func)
- `HandleTable`: `anyToCell` (func), `appendAnyBox` (func), `appendHostObject` (func), `canonKeyOf` (func), `escape` (func), `fetchAny` (func), `fetchAnyBox` (func), `fetchClosure` (func), `fetchDateTime` (func), `fetchDecimal` (func), `fetchDuration` (func), `fetchHostCallback` (func), `fetchHostObject` (func), `fetchList` (func), `fetchRange` (func), `fetchRegexEx` (func), `fetchString` (func), `getAs` (func), `idxOf` (func), `initialCapacity` (var), `isConst` (func), `isEscaped` (func), `isFrozen` (func), `isLiveHandle` (func), `isType` (func), `liveCount` (func), `makeId` (func), `markFrozen` (func), `pinAnyBox` (func), `pinConst` (func), `pinHostClosure` (func), `promote` (func), `release` (func), `releaseConst` (func), `resetForTest` (func), `slotCount` (func), `syncFrom` (func), `syncTo` (func), `tagOf` (func), `tagOfHandle` (func), `tagOrZero` (func), `tokenOf` (func), `windowBaseOf` (func), `windowCapOf` (func), `windowUsed` (func)
- `HelperAddresses`: `dispatch` (func), `dump` (func)
- `HelperCore`: `ctxWriteCode` (func), `ctxWritePanic` (func)
- `HelperId`: `isFixed` (func)
- `HostCallback`: `let fn: Any`, `let sig: ?SignatureDescriptor`, `ti` (let)
- `HostFault`: `causeOf` (func), `clear` (func), `exceptionOf` (func), `record` (func), `takeCause` (func)
- `HostFieldAccessor`: `accepts` (let), `getter` (let), `setter` (let)
- `HostFieldTable`: `find` (func), `register` (func), `resetForTest` (func)
- `HostSignature`: `arity` (func), `display` (let), `paramNames` (let), `ret` (let), `sameShape` (func)
- `InsnDecoder`: `decode` (func), `i32` (func), `i64` (func), `rel32` (func), `u8` (func)
- `Interp`: `align16` (func), `constHandle` (func), `frameInfo` (func), `frameSize` (func), `pinnedConstIds` (func), `result` (func), `run` (func)
- `InterpRunner`: `func engine(): DiffEngine`, `isAvailable` (func), `run` (func)
- `IterTable`: `genOfCursor` (func), `idxOfCursor` (func), `key` (func), `liveCount` (func), `makeCursor` (func), `next` (func), `open` (func), `value` (func)
- `JitArtifacts`: `codeOf` (func), `let fnIds: Array<UInt32>`, `let lengths: Array<Int64>`, `let offsets: Array<Int64>`
- `JitBindSupport`: `HOST_OBJECT_CODE` (let), `UNIT_CODE` (let), `acceptsInterface` (func), `bindName` (func), `bindNameOf` (func), `enrollInterfaceOf` (func), `enrolledOf` (func), `isInterface` (func), `parentsOf` (func), `typeMismatch` (func)
- `JitBindings`: `ctorOf` (func), `empty` (func), `fieldOf` (func), `ignored` (let), `isEmpty` (func), `staticOf` (func), `statics` (let), `withOverrides` (func)
- `JitCompiler`: `static func compileUnit(unit: LoadedUnit): ?JitArtifacts`, `compileUnitWith` (func)
- `JitContext`: `attachDump` (func), `cp` (func), `create` (func), `dumpPointer` (func), `readAt` (func), `resetForCall` (func), `wrap` (func), `writeAt` (func)
- `JitException`: `cause` (let), `sourcePos` (let)
- `JitExecutor`: `create` (func), `invoke` (func), `invokeFn` (func), `pinnedConstIds` (func), `release` (func)
- `JitFieldBinding`: `let get: (Object) -> Any`
- `JitFunction`: `isJitBacked` (func)
- `JitHost`: `findSignature` (func), `registerSignature` (func), `signatureCount` (func)
- `LoadedUnit`: `consts` (let), `dir` (let), `let header: FbcHeader`, `requiresClassRegistry` (func), `rules` (let), `types` (let)
- `LocalType`: `hasBoxPoint` (func), `isConvertible` (func), `isHandle` (func), `isJson` (func), `isLegal` (func), `isSameOrDescendant` (func)
- `LocalTypes`: `get` (func), `isHandleSlot` (func), `read` (func), `validate` (func), `write` (func)
- `MachineEnv`: `setFnTableBase` (func)
- `NameEntry`: `keyLess` (func), `read` (func), `slot` (let), `strLen` (let), `strOff` (let), `write` (func)
- `NameTable`: `at` (func), `decode` (func), `encode` (func), `freeze` (func), `isFrozen` (prop), `strBytesSize` (prop), `validate` (func)
- `NativeAssets`: `liveCount` (func), `resetCounters` (func)
- `NativeMem`: `static var freeCount: Int64 = 0`, `static var mallocCount: Int64 = 0`, `outstanding` (func), `resetCounters` (func)
- `NativeRunner`: `func engine(): DiffEngine`, `isAvailable` (func), `run` (func)
- `OpInfo`: `OPCODE_TABLE` (let), `cat` (let), `fmt` (let), `len` (let), `operandSize` (func), `selfCheckOk` (func)
- `PromotionGroup`: `contains` (func), `release` (func), `snapshot` (func)
- `PublicField`: `hasSignature` (func), `sigParamNames` (let), `sigParams` (let), `sigRet` (let), `sigRetName` (let)
- `ReflectAnyHolder`: `var anything: Any`, `let flag: Bool`
- `ReflectBox`: `var value: T`
- `ReflectUser`: `age` (prop), `bump` (func), `counter` (var), `label` (prop), `parse` (func), `let raw: Int32`, `version` (let)
- `RegistrationException`: `kind` (let), `occupiedBy` (let)
- `RuntimeEnv`: `clearDeadline` (func), `deadlineExpired` (func), `deadlineNanos` (var), `deadlineNanosOf` (func), `nowNanos` (func), `setDeadline` (func)
- `SignatureDescriptor`: `isLegalCode` (func), `paramNames` (let), `let ret: UInt16`, `validate` (func)
- `SignaturePlan`: `marshalArgs` (func), `ret` (let), `sameShape` (func)
- `SignatureRegistry`: `adapterOf` (func), `count` (func), `find` (func), `get` (func), `register` (func), `resetForTest` (func)
- `SignatureTable`: `MAX_ENTRIES` (let), `buildCount` (func), `enabled` (var), `entryCount` (func), `getOrBuild` (func), `resetForTest` (func)
- `SignatureVerifier`: `cached` (func), `verifyReflective` (func)
- `SiteEntry`: `column` (let), `line` (let), `off` (let), `read` (func), `write` (func)
- `SiteTable`: `at` (func), `decode` (func), `encode` (func), `freeze` (func), `hasExact` (func), `isFrozen` (prop), `validate` (func)
- `SourceCompileException`: `column` (let), `hint` (let), `kind` (let), `line` (let), `lineText` (let), `position` (let)
- `SourcePos`: `column` (let), `line` (let)
- `SourceUnit`: `raw` (let)
- `StubRunner`: `func engine(): DiffEngine`, `func isAvailable(): Bool`, `func run(_: DiffCase): DiffOutcome`
- `TCase`: `hit` (func)
- `TMapping`: `caseName` (let), `inScope` (let), `steps` (let)
- `TextFormat`: `bool` (func), `dateTime` (func), `decimal` (func), `duration` (func), `f64` (func), `i64` (func), `offsetText` (func), `pad2` (func), `pad4` (func), `pad9` (func), `range` (func)
- `TypeNames`: `codeOf` (func)
- `UserHelperEntry`: `let ret: UInt16`
- `UserHelperTable`: `find` (func), `push` (func), `resetForTest` (func)
- `Version`: `supportedMajors` (func)
- `X86Compiler`: `compileFunction` (func), `compileFunctionWith` (func)

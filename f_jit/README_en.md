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
import fountain::f_jit.base.DummyDiagnosticsSink

main() {
    let c = Compiler(CompileOptions(DummyDiagnosticsSink()))
    c.registerType<User>()                              // expose a host class to the dialect
    let f = c.compile('{ u: User => u.name }')          // compile (result cached in CompileCache)
    let name = f.call<String>([User('bob', 1)])         // call it
    println(name)                                       // bob
}
```

Interruptible call with a deadline:

```cangjie
var ctx = CallContext()
ctx.deadline = Some(DateTime.now() + Duration.second * 1)   // throws InterruptedException
let v = f.invoke<Int64>([Int64(100_000_000)], ctx)
```

Returning a closure (escaping closure — must be `close()`d):

```cangjie
let f = c.compile('{ n: Int64 => let xs = [n, n + 1]\n { i: Int64 => xs[i] } }')
let g = f.callForFn<(Int64) -> Int64>([Int64(7)])
println(g.call<Int64>([Int64(1)]))    // 8
g.close()                             // the only release path for the promotion group
```

---

## 2. API

| Type | Purpose | Key members |
|---|---|---|
| `Compiler` | Facade: register host capabilities + compile | `registerType<T>()`, `registerClass(desc)`, `registerFunction(f)`, `compile(src)` |
| `CompileOptions` | Compile options | `jit: JitMode` (`Auto`/`Force`/`Off`), `strictFp` (default `true`), `verMajor`, `cpuFeatures`, `diagnostics` |
| `JitFunction` | Compiled unit / callable object | `call<T>(args)`, `invoke<T>(args, ctx)`, `callForFn<Fn>(args)`, `close()`, `isClosed` |
| `JitException` | Runtime failure (`base` package) | `code` (`ErrCode`), `site` (line:column / byte offset), `report` |
| `CompileCache` | Compile cache (key includes `strictFp`/`verMajor`) | `lookup`, `reset`, `runs` |
| `CallContext` | Call context | `deadline` (interrupts at safety points → `InterruptedException`) |
| `PredefinedFunction` / `ClassDescriptor` / `PublicCtor` / `PublicField` | Host registration surface | Functions/classes/ctors/fields callable from the dialect |
| `DbgDump` | Variable dump on failure (name/value/type) | Triggered by the diagnostics sink |
| `JitReport` | Execution report (incl. `-1` DEOPT semantics) | Consumed by the bridge inside `call` |

Packages (`fountain::f_jit.*`): `base` (contracts, error codes), `bytecode` (`.fbc` encode/decode/load),
`compiler` (front-end + lowering), `runtime` (interpreter, handle table, helpers), `backend` (two native
backends), `test.diff` (three-engine differential tests only).

---

## 3. How it works

**① Compile**: lexer/parser → AST → type checking → **stack bytecode** (157 opcodes, see
`doc/jit-bytecode-m1.md` §5). The `.fbc` container holds a header (`magic/verMajor/verMinor/crc32`…),
code section, constants, type tables, site table, function directory and a variable-name section.
Bytecode is **architecture-neutral**.

**② Execute (three engines)**:

| Engine | Implementation | Notes |
|---|---|---|
| `Interp` | Pure Cangjie interpreter | Reference semantics; fallback on every platform |
| `BackendX86_64` | `X86Lower` → machine code | Linux x86_64; three passes (probe → CFG depth → emit) |
| `BackendAArch64` | `A64Lower` → machine code | Linux aarch64; dedicated operand-stack pointer `x20` |

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
release path is `JitFunction.close()`.

**⑥ Fail-and-fallback (deopt)**: `errCode = -1` means "replay this call in the interpreter"; the bridge
does that transparently. Any other code (1/2/3/6/7/8/16/18/19/21/22…) surfaces as `JitException`.

---

## 4. Support matrix (bytecode vs native code)

| Layer | Supported | Evidence |
|---|---|---|
| **Bytecode** (compile / interpret / `call`) | **Any platform that runs Cangjie 1.3.x** (Linux / Windows / macOS, x86_64 / aarch64); architecture-independent | `.fbc` is plain data; `Interp` is pure Cangjie |
| **Native code (JIT)** | **Linux x86_64 only**, **Linux aarch64 only** | `backend/JitExecutor.cj`: requires `OS.current.isLinux` and `Arch.current ∈ {X86_64, AArch64}`; otherwise the whole unit runs in the interpreter |
| x86_64 prerequisite | **SSE4.1** (for `roundsd`-style rounding); without it, units containing rounding ops are not JITed | `X86Lower.floatRoundChecked` / `CpuFeatures.hasSse41` |
| aarch64 prerequisite | None (no CPUID branch) | — |

> Bottom line: **the same `.fbc` runs on all four platforms**; **Linux x86_64 / Linux aarch64 execute
> native code**, Windows / macOS execute the interpreter (different speed, identical semantics).

---

## 5. When JIT is skipped (by design)

JIT is an accelerator; on any of the following, the **whole unit** falls back to the interpreter
(`ok = false`) — semantics unchanged, only slower:

| Category | Examples |
|---|---|
| Rejected at assembly time | `DT_NEW` (0xA9), `DUR_NEW` (0xAA) |
| Missing runtime facilities | needs a constant mirror but `constBase == 0`; needs a function table but `fnTableBase == 0` |
| Platform capability | x86 without SSE4.1 and the unit contains rounding ops |
| Statically unprovable | inconsistent operand-stack depth at a merge; emit audit finds an out-of-set memory base (only stack/frame/ctx allowed) |
| Unimplemented | unknown opcode (anything not yet lowered falls back) |

---

## 6. FAQ

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

| Case | Handling | Resident? |
|---|---|---|
| Non-escaping (inside the window) | `call`'s `finally` → `resetWindow(-1)`: `alive=false`, `objs[i]=0`, `gen+1` | No longer referenced by f_jit ⇒ collected by GC |
| Returned handle | `releaseReturnHandle` releases it right after unboxing (`JitFunction.cj:477-487`) | No |
| Escaping closures / captures | Owned by `PromotionGroup`; **`JitFunction.close()` is the only release path** | Stays resident until the host calls `close()` (contract, not a bug) |

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

## 7. Known limitations

- Native code only on Linux x86_64 / aarch64 (all other platforms interpret);
- x86_64 requires SSE4.1 (units with rounding ops are not JITed otherwise);
- one H22 `interrupt_poll` per loop back-edge; on tight loops this call (which allocates) is costly —
  tracked in `doc/spec/f-jit-m1/verify.md`;
- escaping closures must be `close()`d, otherwise their promotion group stays resident;
- specifications: `doc/jit-bytecode-m1.md` / `doc/design-m1.md` / `doc/plan-m1.md`; acceptance:
  `doc/spec/f-jit-m1/verify.md`; performance: `doc/perf-m1.md`.

# Design：x86_64 栈深度 CFG 化（修复分支汇合后的对齐错误）

## 1. 根因（已定位，含证据）

### 1.1 现象

| 用例 | 输入 | 期望 | 实际 |
|---|---|---|---|
| `CastOr_test.downcastFallsBackOnMismatch` | `ReflectUser('bob',1)` | 返回 `fallback` | **SIGSEGV**（JIT 内） |
| `CastOr_test.bareCastFailsWithBadCast` | `ReflectUser('bob',1)` | 错误码 **7** | **SIGSEGV** |
| `CastOr_test.unknownClassNameUsesRuntimeCheck` | `'ann'`（类名未跟踪 ⇒ 运行期判定） | `ann` | **SIGSEGV** |

崩溃栈：`JitExecutor.invokeOffLocked`（`JitExecutor.cj:176`）→ JIT 机器码 → `CJ_MCC_N2CStub`，
`signal pc: 0x61a383, addr: (nil)`。三例的**共同点**：`$as$<T>` 返回 false ⇒ **`JZ` 走 fail 分支**；
命中分支的同类用例（`downcastSucceedsWhenRuntimeTypeMatches` 等）全绿。

### 1.2 机制

`lowerCastOr`（`Lowerer.cj:2844–2870`）发射：

```
<e> ; STOREL tmp ; LOADL tmp ; setSite
CALL_HELPER $as$<T> 1      ; → Bool
JZ fail                    ; ← 运行期深度 0；线性深度 1（then 分支已 +1）
LOADL tmp ; JMP end
fail: <fallback>           ; 或以 H77 抛 7
end:
```

`X86Lower.lower()`（`X86Lower.cj:88–98`）对字节码**线性**扫描，只在每个偏移 `bind('L<off>')`，
**从不恢复 `depth`**；而 `alignBeforeCall()`（`X86Lower.cj:309–315`）用
`pad = (this.depth % 2) != 0` 决定 `sub rsp, 8`。

⇒ fail 分支内 `this.depth` 比运行期多 1，**奇偶取反**：
该分支里的 helper 调用（`argc ≥ 1` 的构造器 `ReflectAdmin("fallback")`、或 `argc = 0` 的 H77
之后的调用序列）拿到错误的栈对齐 ⇒ `call` 时 `rsp % 16 != 0` ⇒ `@C` 入口（`h_dispatch` →
`helperEntry` → 仓颉分配/`movaps` 等对齐敏感指令）故障。

### 1.3 为什么是 x86 专属

- `A64Lower.cj` **没有** `depth` 追踪（grep 无命中），对齐不依赖深度 ⇒ aarch64 不复现；
- `BytecodeBuilder` 侧**本来就有** CFG 化的汇合校验：`emitRel` 记录 `jumpDepth`（`:173–178`）、
  `place()` 恢复 `depth` 并在不一致时报「分支汇合栈深与落点不等」（`:205–237`）——
  即**字节码是深度自洽的**，缺的只是 JIT 降低端的等价分析。

## 2. 方案对比

| 方案 | 做法 | 评价 |
|---|---|---|
| **A（采用）CFG 前扫 + 逐指令深度表** | 降低前做一次控制流数据流分析得 `depthAt[off]`，`lower()` 每条指令前设 `depth` | 正解：与 `BytecodeBuilder` 的语义一致；失败可安全回退；实现局部于 backend |
| B 无条件对齐 | 每次 call 前固定 `sub rsp,8` | 错：奇偶未知，固定补丁在偶数深度时**制造**错位 |
| C 仅在标签处恢复 | 记录跳转点深度、落点恢复 | 不充分：汇合点的期望深度需由**多条前驱**一致推导，等价于 A |
| D 修改 aarch64/共享 ABI | — | 不必要：aarch64 无此缺陷，且会扩大改动面 |

## 3. 实现设计

### 3.1 新增 `X86Depth`（internal，`f_jit/src/backend/X86Depth.cj`）

```cangjie
public struct StackEffect { let pops: Int64; let pushes: Int64 }

// 按 opcode + 操作数给出栈效应；无法判定返回 None
internal func stackEffect(op: UInt8, operands: Array<UInt8>): ?StackEffect

// 控制流数据流：返回每条指令入口深度；汇合不一致 / 未识别指令 / 标签缺失 → None
internal func analyzeDepth(code: Array<UInt8>, codeOff: Int64, codeLen: Int64): ?HashMap<Int64, Int64>
```

- **栈效应表**（按语义分组，与 `Interp` 逐指令实现对照）：
  - `PUSH_*` / `LOADL` / `DUP`：+1；`POP` / `STOREL` / `JZ` / `JNZ` / 二元运算 / `RET`：−1；
  - `CALL_HELPER` / `_NC` / `_V`：`pops = argc`，`pushes = (variant == 2) ? 0 : 1`；
  - `CALL_HOST` / `CALL_CLOSURE`：`pops = argc + 1`、`pushes = 1`；`CALL_FUNC`：`pops = argc`、`pushes = 1`；
  - `JMP` / `LOOP_BACK` / `SET_SITE` / `CHECK_ERR` / `NOP` / `STACK_GUARD`：0；
  - 终止类（`BAIL` / `ABORT` / `RET` / `RET_VOID`）：无后继；
  - 其余已分配 opcode 必须显式登记（**表完整性用例**守护）。
- **数据流**：工作列表从 `codeOff` 出发，深度 0；对每条指令按后继传播
  （`JMP` → 目标；`JZ/JNZ/LOOP_BACK` → 目标 + next；终止类不传播；其余 → next）。
  同一偏移两次到达且深度不同 ⇒ `None`。

### 3.2 接入 `X86Lower`

- `lower()` 开头调用 `analyzeDepth`；`None` ⇒ `this.ok = false; return`（整单元退回解释器，
  与既有「任何失败退回解释器」一致，**不改变语义**）。
- 循环体内：`this.depth = depthAt[off]`（替代线性累加；`bind('L<off>')` 保留供跳转回填）。
- `alignBeforeCall()` 公式**不变**（`depth % 2`），输入改为 CFG 深度。
- `depth` 的其它使用点（`helper` 的 `disp` 计算、`depth - argc + 1` 等）在 CFG 深度下自然正确；
  `disp = 8 * (argc - 1)` 与深度无关，不受影响。

### 3.3 不变项

- `.fbc` 格式 / opcode / helper / 错误码 / 三引擎语义 **零变更**；
- `A64Lower` **零改动**（其不依赖深度）；
- `X86Compiler` 序言/尾声不变（`frameSize` 来自 `fn.maxStack`，与本次无关）。

## 4. 测试策略（TDD）

### 4.1 红（先写，须看着失败）

1. **固化 3 个崩溃用例**（已存在，作为 RED 证据保留）：断言不崩 + 值/错误码正确；
2. **新增同型用例**（覆盖「条件汇合 + 汇合分支内 helper 调用」的其它形态）：
   - 表达式 `if`：`{ b: Bool => (if (b) { "a" } else { s.x }) }` 类形态，else 分支内含 `argc ≥ 1` helper；
   - `while` 回边：循环体内调用 `argc = 2` 的构造器/heper，循环后取值；
3. **字节级断言**（`X86Lower_test`）：给定单元在**汇合点之后**的调用前出现
   `48 83 EC 08`（`sub rsp,8`）且调用后出现对称 `48 83 C4 08`，奇偶与汇合深度一致；
   修复前该断言必须**失败**（证明测到了同一机制）。

### 4.2 绿

实现 §3.1/§3.2，使上述用例全部通过。

### 4.3 回归（批次末）

- **全量 `cjpm test`：1091/1091**（当前 1084/1091，3 ERROR）；
- **三引擎差分**（`test.diff`）逐位一致；
- **性能抽查**：预扫为 O(n) 一次性开销，`PerfCompare_test` 波动在噪声内（记录数字，不设门槛）。

## 5. 兼容性、风险与回退

| 项 | 说明 |
|---|---|
| 语义 | 零变更：失败一律退回解释器（既有纪律） |
| 性能 | 预扫 O(指令数)；若栈效应表遗漏某 opcode ⇒ 该单元**退回解释器**（性能退化，非错误） |
| 风险 | 表不完整 ⇒ 覆盖率下降（用「表完整性用例」+「X86Lower case 集合与 A64Lower 全等」双守护） |
| 回退 | 单提交可回退（`X86Depth.cj` + `X86Lower.lower` 接入 + 用例）；回退后回到「3 例崩溃」，不得发布 |

## 6. 文档同步

- `f_jit/doc/jit-bytecode-m1.md` §12.3（x86 序言/尾声）与 §12.4（降低表）补一句：
  「操作数栈深度 SHALL 由控制流推导；16 字节对齐补丁由该深度决定（`depth % 2`）」；
- `f_jit/doc/spec/f-jit-m1/verify.md` 追加本次回归证据（1091 例、修前 3 ERROR、修后全绿）；
- `design-m1` 附 C 若有对齐说明则同步（无则不动）。

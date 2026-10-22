# Proposal

## Why

M1/M2/M3 的能力矩阵在纸面上完整（1026 条用例、T 系列全覆盖），但 2026-10-20 的全量审查（`reviews/202610202219_f-jit-completeness/`：`summary.md`、`todo.md`、`verify_r4.md`、`verify_r3r5.md`、`verify_r1r2r6.md`）把「规格条目 → 代码落点 → 用例断言」逐条对拍后确认 **26 条严重缺陷**。它们不是遗漏的功能点，而是**已宣称交付的能力在真实调用路径上是坏的**：

- **P0（6 条，不可用）**：`as 某宿主类` 在运行期必然以 `8` 失败或返回错 tag 句柄（H80 typecode=14）；`call<Any>` / `call<JsonXxx>` 在宿侧直接被「T 不是可解包类型」挡死，`CallMarshal` 的 15/16–19 行永远走不到；`BNOT_I` 不弹操作数且结果恒为 −1；DEOPT 重放复用上一次的错误槽（起始 `errCode = -1`），解释器把它当「已失败」直接中止，重放失败也不会被复查；`CallContext.deadline` 没有任何入口能写进运行期，`interrupt_poll` 的 −2 路径在真实调用中永不可达。
- **P1（9 条，静默错算）**：正则 `flags` 在词法层丢失、`String` 上的 `-` / `*` / `/` / `%` 被静默当数值运算（`+` 则一律拼接）、尾递归实参逆序写回形参槽导致自覆盖、`else if` 直接语法错误、IIFE 返回类型恒 `I64`、同名实例方法只取首个重载、常量 Map 键的规范键前缀与运行期不一致（跨类型键永不命中）、`lowerExprAs` 对不可转换的期望类型静默放行、`List<Any>` 调用实参未装箱。**这批最危险：不抛异常、不给错误码，只给错结果。**
- **P2（6 条，资源与并发）**：`fetchAnyBox` 缺 gen 校验（旧 ID 可读新盒）、`IterTable` 的 `clearAll` 只在测试里被调、逃逸槽释放后不归还 `freeSlots`（永久泄漏）、`callForFn` 未进调用锁、AArch64 `imm9` 越界静默截断、H80 的 `as` 路径不走窗口记账。
- **P3（5 类，文档与矩阵失真）**：① helper 编号整表错位（文档 H66–H68 / H73–H75，代码 H78–H83）；② 三条已被推翻的表述仍写在当前规则（二次装箱报错、`{ "a" : 1 }` 语法错误、LocalType 16–255 拒绝）；③ `json_set` 值域规格含 Float64、运行期以 8 拒绝；④ 矩阵虚报（T48/T51 恒 4 记 full、四类插入点③无正向用例、只读字段写规格 19/实现 20、M3 三引擎零证据）；⑤ `doc/spec/` 缺 proposal/design/tasks（自检发现）。

不修的后果是**能力矩阵继续失真**：宿主按文档调用 26 条里的任意一条，要么拿到错结果（无声），要么拿到与规格无关的错误码，排障成本远高于重写。这批必须在本轮一次收口，且每条都必须有**先红后绿**的用例做证据。

## What Changes

- **P0 六条根治**：
  - H80/H79 的 14 目标改为「类界判定 + 正确 tag」：`aux` 承载 `$as$<C>` 的 16 位 helper id，命中后按 `TypeToken.HOST_OBJECT`（tag 11）登记并计入窗口；未命中仍为 22。**不新增 opcode、不改 `.fbc` 格式**（14 的 `aux` 原为恒 `0xFFFF`）。
  - `localTypeOf<T>` 补齐 `Any`（15）与 JSON 谱系（16–19），使 `CallMarshal` 的 15/16–19 行在宿侧可达；`retType=15` 的逃逸/拆盒与 `16–19` 的 tag 11 例外行走同一张表。
  - `BNOT_I` 改为「弹 1 个操作数、压回 `~a`」，与 A64 降低逐位对拍。
  - DEOPT 三态收尾改为「重放前 `errCode = 0` → 重放 → **复查** `errCode`：0 走值路径，>0 走 `throwJit`，−2 抛中断」，重放异常兜底 99 的既有契约不变。
  - 新增 `JitFunction.invoke<T>(args, options: CallContext)`：按 `options.deadline` 写入 `RuntimeEnv`（栈式保存/恢复，支持重入），`call<T>` 委托为 `invoke(args, CallContext())`。
- **P1 九条纠偏**：词法保留 `flags`；`-` / `*` / `/` / `%` 的 String 组合显式报编译错误，`+` 仍走 `STR_CAT`；尾递归实参改经临时槽求值后再写形参；`else if` 走「先判 `KwIf` 再判块」；IIFE 取闭包真实返回类型；`methodOf/requireMethod` 支持按实参静态类型选重载；常量键统一 `i:` / `f:` / `s:` / `d:` / `t:` / `u:` / `r:` / `x:` 前缀与运行期同构；`lowerExprAs` 末段对不可转换组合 `diagFail`；容器字面值进 `Any` 形参/返回值时整体装箱。
- **P2 六条收口**：`fetchAnyBox` 补 gen 校验（与 `fetchHostObject` 同构）；`IterTable.clearAll` 进桥的 `finally` 并加锁；`release` 对逃逸槽复位 `escapeFlags` 并归还 `freeSlots`；`callForFn` 进 `callMtx`；A64 `ldrOff/strOff` 越界改走「`movImm64` + 加基址」慢路径；H80 的 14/容器 pin 走 `append` 系（窗口记账）。
- **P3 五类回写**：helper 编号全表替换；三条推翻表述改为当前规则；`json_set` 值域三处统一；矩阵虚报逐条纠正（T48/T51、③、只读 20、M3 三引擎）；缺件目录补齐三件套。
- **TDD 纪律**：每条缺陷先写**会失败**的用例（多数是现有用例断言过弱导致的假绿），再改实现；每批次跑 M1/M2/M3 全量零回归。
- **无兼容性破坏**：`.fbc` 格式、v1/v2/v3 规则集、公开错误码、既有 helper 编号全部不变；唯一新增公开 API 是 `invoke`（纯增量）。

## Capabilities

### New Capabilities

（无。本次是既有能力的实现纠偏，不新增 capability。）

### Modified Capabilities

- `f-jit-runtime`：H78–H80 的 14 目标类界与 tag、H80 窗口记账、`BNOT_I` 栈纪律、DEOPT 重放的三态收尾、`IterTable` 生命周期、`fetchAnyBox` gen 校验、逃逸槽归还。
- `f-jit-compiler-frontend`：正则 `flags` 保留、String 算术拒绝面、尾递归实参求值顺序、`else if` 语法、IIFE 返回类型、实例方法重载解析、`lowerExprAs` 的转换完备性、`List<Any>` 实参装箱。
- `f-jit-facade-bridge`：`CallMarshal` 的 15/16–19 行宿侧可达、`invoke/tryInvoke` 与 deadline 接线、`callForFn` 串行化。
- `f-jit-bytecode-format`：常量 Map 键的规范键前缀（拼装期与运行期同构）。
- `f-jit-backend`：AArch64 `ldr/str` 的 `imm9` 范围判定与慢路径回退。
- `f-jit-differential-acceptance`：26 条缺陷的回归用例落点、M1/M2/M3 零回归门槛、T 矩阵「结构 / 语义」分层、文档失真回写。

## Impact

- **代码**：`f_jit/src/runtime`（`AnyHelpers`、`Interp`、`HandleTable`、`IterTable`、`RuntimeEnv`）、`f_jit/src/compiler`（`Lexer`、`Parser`、`Lowerer`、`ClassRegistryView`）、`f_jit/src/bytecode`（`ConstRegistry`）、`f_jit/src/backend`（`A64Emitter`）、`f_jit/src` 根包（`JitReport`、`JitFunction`、`CallMarshal`）、`f_jit/src/base`（`CallContext` 注释口径）。不新增模块，不改根 `cjpm.toml`。
- **API**：新增 `JitFunction.invoke<T>(args: Array<Any>, options: CallContext)`；`call<T>` 行为不变（等价 `options = CallContext()`）。其余均为内部修正。
- **格式与兼容**：`.fbc` verMajor 1/2/3 及规则集校验**零变化**；`aux` 的 14 目标编码从「恒 `0xFFFF`」放宽为「`$as$<C>` helper id 或 `0xFFFF`（不核对）」，读写两侧同一版本内自洽，不产生跨版本差异。
- **错误码**：不新增；22（ANY_CAST）/ 8 / 16 / 99 的既有分工不变，只把「本该 22 却报 8」的口径纠正。
- **平台**：解释器与 AArch64 为原生证据；x86_64 机器码断言按既有条件跳过策略执行。
- **测试**：26 条专项回归 + 三档全量（M1/M2/M3）零回归；差分最小集仍为 `Interp × AArch64`。
- **文档**：`jit-bytecode-m3.md`、`design-m3.md`、`plan-m3.md`、`f_jit/doc/spec/f-jit-m3/**`、`f_jit/doc/spec/f-jit-m2.1–m2.3/**` 按本次结论订正；OpenSpec 产物落 `openspec/changes/fix-f-jit-audit-defects/` 与 `f_jit/doc/spec/fix-f-jit-audit-defects/`。
- **不在本次范围**：R4.5 的「容器转型退化路径」（P2 结案已是校验路径）、CALL_HOST 转发特化（T56）的收益优化、M3 之外的 M4 能力。

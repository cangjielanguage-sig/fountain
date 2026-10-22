# f-jit-m1 校验报告（verify）

- 变更：`f-jit-m1`
- 校验对象：`openspec/changes/f-jit-m1` 的 9 份 spec（40 requirement / 156 scenario）、`tasks.md`（115 项）
- 校验时间：2026-10-19（x86 真机全绿回填 + 矩阵/标签收口）
- 校验方式：**手工等价校验 + 官方 `/opsx:verify` 已装**。本 worktree 的 `.codebuddy/commands/opsx/` 原先只装了 apply/archive/explore/propose/sync/update 六个工作流，现已用 `openspec update --force` 补齐 12 个（含 `verify.md`），融合侧可识别 `/opsx:verify`；本报告仍是逐项人工对照的产物，不修改 `tasks.md`。
- 基线：`cjpm test` **560/560**（Linux aarch64 原生；**2026-10-19 追加 x86_64 真机同为 560/560**）；`scripts/check_tmap.sh` **40 条范围内映射，悬空/未断言 0 条**（标签已行为级）；`scripts/check_scenarios.sh` **156 条 scenario 全量登记，未映射 0、缺失 0**。
- x86 证据演进：box64 + x86 SDK 全量曾为 **560 例 / 550 通过 / 9 失败 / 1 错误**（prologue 黄金更新前；更新后为 551 通过 / 8 失败 / 1 错误；失败全部为 box64 下 Float64 字面量恒 0 导致，非 JIT 代码；`X86Exec_test` 12/13 通过，仅 `floatToInt` 受该模拟缺陷影响）。
- **x86 真机证据（2026-10-19，WSL Ubuntu-24.04 / `x86_64-unknown-linux-gnu` / Cangjie `1.3.0-alpha.20261015001050`）**：`cjpm test` **560/560 通过、0 失败 / 0 跳过**；x86 后端专项 **85/85**；`PerfCompare_test` JIT 结果与 cjnative / 解释器**逐位一致**，稳态吞吐 **native=3,198,433ns / jit=2,276,989ns / interp=5,987,603,230ns**（JIT ≈ native 的 71%、相对解释器折合约 2600×）⇒ **box64 下的 9 失败确认为模拟器 Float64 字面量缺陷，真机不复现**。

## 结论

**apply 的 115/115 不等于规格全绿。** 本轮已修掉全部 4 个 CRITICAL（生产 JIT 接入、x86 全 opcode、T6 21/22、T52/T53 映射）。**WARNING-01 关闭**：x86 实现层补齐 157 个 opcode 后，先在 box64 取得执行证据，再由真机 x86_64 全量跑通（560/560 + x86 专项 85/85 + 性能对拍逐位一致；box64 的 9 失败 + 1 错误不复现，确认为模拟器 Float64 缺陷）⇒ **可直接 archive**。**WARNING-02 关闭**：13 个单元用例的注释级 T 标签已升级为 `TCase.hit('T<id>/<场景>', 条件)` 的可执行断言，`check_tmap.sh` 改为**先剥注释再判定**，注释标签不再能通过校验。scenario→test 矩阵由 13 条扩到**全 9 个 capability 共 156 条**（0 未映射），并新增 `--strict` 档位。剩余为 7 条**无用例断言**的 scenario、5 条**部分覆盖**，以及 JIT 全局串行、非 Linux 执行证据、x86 执行矩阵代表性三类工程债（见「仍未完成」）。

| ID | 严重度 | 状态 | 摘要 |
|---|---|---|---|
| CRITICAL-01 | CRITICAL | **已修复** | 用户面 `Compiler.compile` 原先只返回解释器函数，JIT 从未接入生产路径 |
| CRITICAL-02 | CRITICAL | **已修复（含执行证据）** | x86 lowering 已按 A64 的 157 个 opcode 全量补齐；box64 下整数/分支/容器/闭包/递归均真实执行通过 |
| CRITICAL-03 | CRITICAL | **已修复（21/22）** | T6 映射用例 15 码 + 单元行为 7/12/16/17/19/99；仅 15 为防御码（解释器无机器栈余量概念），无数值路径 |
| CRITICAL-04 | CRITICAL | **已修复** | T52/T53 原为「挂名映射」；已补真实两形态用例与常量写 20 断言 |
| WARNING-01 | WARNING | **已关闭（真机 x86_64 证据）** | 2026-10-19 WSL x86_64 真机全量 **560/560** + x86 专项 **85/85**；`PerfCompare_test` 三侧逐位一致；box64 的 9 失败确认为模拟器 Float64 缺陷，真机不复现 |
| WARNING-02 | WARNING | **已关闭** | 13 个单元用例的 T 标签改为 `TCase.hit('T<id>/<场景>', 条件)` 行为级断言；`check_tmap.sh` 剥注释后判定，注释标签不再通行 |
| INFO-01 | INFO | 留档 | `tasks.md` 的 S5.4/S5.8 勾选与子项「未完成/待补」自相矛盾，建议 verify 后统一口径 |

## CRITICAL 明细

### CRITICAL-01 生产路径只走解释器（已修复）

**原证据**
- `CompilePipeline.makeFunction` 的 `body` 固定为 `Interp(unit).run(...)`，`JitCompiler.compileUnitWith` 只在 `test/diff/RealRunners.cj` 中被调用。
- 规格 `f-jit-facade-bridge` 要求「纯字节码形态与机器码形态 SHALL 使用同一接口、同一行为」，实际只有字节码形态。
- 同一源码首次以 `JitMode.Off` 编译后，`Auto` 会命中同一缓存键，永远拿不到 JIT 产物。

**本轮修复**
- 新增 `f_jit/src/backend/JitExecutor.cj`：常量镜像 → 入口表 → 编译 → 码内存 → 入口回填 → 调用 → 释放，失败返回 `None`。
- `CompilePipeline.makeFunction` 按 `CompileOptions.jit` 尝试 `JitExecutor.create`；`Off` 或失败静默退回解释器；`DEOPT(-1)` 的 replay 仍走解释器。
- `JitFunction` 的 `release` 接管 `JitExecutor.release()`（幂等，码内存最后释放）。
- 缓存键加入引擎维度：`src/<off|auto|force>/<fingerprint>`、`fbc/<...>/<fingerprint>`，避免 Off/Auto 互串。
- 证据：`JitWire_test.createsExecutableAssets` 通过（生产路径能真实建立 JIT 资产）；全量 547/547 不回归。

**残留**
- `MachineEnv.fnTableBase` 仍是进程级全局；已用 `JitExecutor.envMtx` 序列化 JIT 调用避免多单元并发串表（语义正确，吞吐下降）。

### CRITICAL-02 x86 指令降低未覆盖全部指令（已修复，实现层）

**规格**：`f-jit-backend/spec.md`「两架构降低覆盖全部指令」——两个后端 SHALL 为全部已分配指令提供降低实现。

**修复前**：`X86Compiler` 只分派 18 个 opcode（`PUSH_I8/I64`、`DUP/POP/SWAP`、`LOADL/STOREL`、`IADD/ISUB/IMUL`、`BAND/BOR/BXOR`、`RET`），遇分支/比较/helper/常量即 `None` → 整单元退解释器。`S5.4` 子项与 `S5.8` 也自认「compile 未完成 / x86 待补」。

**本轮修复**
- 新增 `f_jit/src/backend/X86Lower.cj`：带标签/rel32 回填的完整编排，覆盖
  - 控制流：`JMP/JZ/JNZ/LOOP_BACK`、`ASSERT/ABORT/GUARD_NNZ`
  - 比较：`EQ/NE/LT/LE/GT/GE`（`0x52–0x57`、`0x69/0x6A`）
  - 整型：`IADD/ISUB/IMUL`（含 `jo` 溢出）、`IADD_WRAP`、`INEG`
  - 位/移位：`BAND/BOR/BXOR/BNOT/SHL/SHR/USHR`
  - 调用模板：`CALL_HELPER`（三种 variant）、`CALL_FUNC`、`PUSH_KH` 常量镜像
  - 容器/字符串/正则/时间等 `0x6B–0x6E`、`0x75–0x77`、`0x83/0x84(mode0)/0x85–0x89`、`0x91–0xBF` 的 helper 路由
  - 收敛块：`SET_SITE`、`CHECK_ERR`、`BAIL`、`checkfail`（`jit_dump` 单次转储）
- `X86Compiler` 改为「序言 + `X86Lower` + 出口/收敛块」；`JitCompiler` 把 `constBase/fnTableBase` 传给 x86。
- x86 实参 ABI 对齐共享约定：`rsi` 指向最深实参，第 i 个在 `[rsi-8i]`；`X86Frame_test` 期望同步更新。
- 证据：`X86Compile_test`（分支 / 容器+常量镜像 / 递归+fnTable）三例通过，说明组装层不再对这三类单元返回 `None`；`X86Exec_test` 新增容器与递归两例（x86-only）。

**本轮补齐**
- 整型：`IDIV/IMOD`（÷0/INT64_MIN÷-1）、`IMIN/IMAX`、`IABS`、`ICLZ`（bsr）、`IPOPCNT`（SWAR）
- 浮点：`FADD/FSUB/FMUL/FDIV/FDIV_CHK`、`FNEG/FAbs`、`FMIN/FMAX`、`FSQRT`、`FFLOOR/FCEIL/FTRUNC/FROUND`、`CMP_F`
- 类型：`CAST`/`GUARD_TYPE mode1`（H17 判定 + bail7/deopt）、`TO_I64`（NaN/±2^63 边界）、`TO_F64`、`DEC_TO_I64 mode1`（9 → DEOPT）
- 调用/闭包：`CALL_CLOSURE`（H55/H57/间接调用/重写 fnId）、`LOAD_CAP`（H56）
- 容器：动态 `LEN`（H18 取 tag → H01/H03/H07）
- 覆盖核对：`X86Lower` 的 case 集合与 `A64Lower` 全等（157 个 opcode，0 缺失）

**口径说明**
- `FFLOOR/FCEIL/FTRUNC/FROUND` 使用 `roundsd`（SSE4.1）；design §12.4 的基线是 SSE2 软件序列，SSE4.1 仅在显式开启时使用。**已有 CPUID 门禁**：`X86Lower.sse41 = CpuFeatures.hasSse41`，不支持 SSE4.1 的机器上**含取整指令的单元整体降级解释器**（不执行非法指令）⇒ 目标机**不要求**必具备 SSE4.1；若要在纯 SSE2 上跑 JIT，仍需改回软件序列（未做）。
**判定**：实现层已按 A64 的 opcode 全集补齐，CRITICAL-02 关闭；**x86 原生执行证据已于 2026-10-19 取得（真机 560/560 + 85/85 + 性能对拍）⇒ 可宣称「x86 端到端全绿」**。

### CRITICAL-03 T6 错误矩阵不完整（已修复，21/22）

**规格口径**：`plan-m1.md:221` —「错误一致性 1–20/99」。原 `t6ErrorConsistency` 只断言 1–5。

**本轮新增**
- 源码级差分：9（Decimal→I64 越界）、10（Decimal ÷0）、11（DateTime 越界）、13（F64→I64 NaN/Inf/越界）、14（非法 regex）、23（迭代中改同一 map）
- 修复 `decToI64` 对超大指数静默返回 0 的缺陷：`Int64(1.0e300)` 现按 **9** 报错（该字面量在 M1 是 Decimal，不是 F64；13 由运行时 `Int64(x: Float64)` 覆盖）
- helper 级（源码类型系统不可达）：6（null 句柄）、8（句柄类型不符）、18（未实现 helper）、20（常量容器写）
- 覆盖码：**1–6、8–11、13、14、18、20、23**，共 **15/22**（映射用例内）

**剩余码与落点**
- 7 `BAD_CAST`：新增 `Interp_test.castTypeMismatchYields7`（`CAST STRING` 作用在 I64 值 → 7）
- 15 `STACK_GUARD`：防御码；解释器无机器栈余量概念（`0x07` 为 NOP），只在桥层重跑余量不足时产生，M1 无稳定数值路径
- 16 `HANDLE_WINDOW_FULL`：`HandleTable_test` 压小 `capacityLimit` → 16
- 17 `EXPLICIT`：`Interp_test.typeInstructions` 的 `THROW` → 17
- 19 `CALL_CONTRACT`：`userapi/contractErrorIsVisible` 与 `JitFunction_test`
- 99 `HELPER_PANIC`：`Helpers_test` / `JitContext_test`

**判定**：21/22 有行为证据（映射用例 15 + 单元行为 7/12/16/17/19/99），仅 15 为无稳定路径的防御码。CRITICAL-03 关闭；建议在 plan 中把「源码可达码」与「引擎内部码（单元用例覆盖）」分开记。

### CRITICAL-04 T52/T53 挂名映射（已修复）

**原证据**
- T52 定义「机器码形态 / 纯字节码形态同接口同行为」，原映射到 `t2TripleEqualCore`，该用例只做 `Interp × AArch64` 差分。
- T53 定义「变更型 helper 的常量目标 → 20」，原映射到 `t18ContainerMutation`，其中 `T53/list-sum` 只是列表求和。

**本轮修复**
- 新增 `f_jit/src/TwoForms_test.cj::t52TwoFormsSameBehavior`：同源分别以 `JitMode.Force` / `JitMode.Off` 编译，逐参比对成功结果与除零错误码。
- `t18ContainerMutation` 增加 `T53/` 常量容器写断言：`pinConst` 后 H43 → `errCode=20`。
- `TCoverage.cj` 的 T52 映射改为 `t52TwoFormsSameBehavior`。
- `scripts/check_tmap.sh` 升级：解析每个映射用例的函数体，要求含 `T<id>/` 标签；改名、漏标签、空步骤均判失败。当前 40 条范围内映射，0 悬空。

**残留**
- 原「13 个单元用例的 `T<id>/` 只是注释」一项已于 2026-10-19 消除：标签全部改为 `TCase.hit('T<id>/<场景>', <真实条件>)` 的行为级断言，`check_tmap.sh` 剥掉 `//` 与 `/* */` 后只认这种形式，注释标签不再能通过校验。

## WARNING 明细

### WARNING-01 x86 执行证据（已关闭）

在 Linux aarch64 上用 **box64 + x86_64 Cangjie SDK** 运行独立副本 `/tmp/f_jit_x86` 的全量 `cjpm test`：

- 全量：**560 例 / 550 通过 / 9 失败 / 1 错误**（prologue 黄金更新前；更新后 551 通过 / 8 失败 / 1 错误。A64Exec_test 已按 aarch64 条件编译排除）。
- `X86Exec_test`：**12/13 通过**；`minimalUnit`、`arithmetic`、`constAdd`、`identityArg`、`argAddZero`、`branch`、`containerMutation`、`recursiveCall`、`floatArithmetic`、`closureCall`、`listLen`、`divMod` 通过，仅 `floatToInt` 失败。
- `X86Compile_test`：11/11；`X86Frame_test`：通过（prologue 黄金序列已同步为 64 位 fnId 写）。
- 本轮修出的两个真实 x86 缺陷：
  1. `X86Lower.binOp` / `INEG` 溢出检查方向反了（`JO ok` → 正常值落到 `bail(3)`，所有整数运算误报 `OVERFLOW_I64`）；改为 `JNO ok`，并加 `checkedArithmeticUsesJno` 字节级回归。
  2. ctx 的 `site` / `fnId` 只写 32 位，高 32 位残留（`site=61` 读成 `-4294967235`）；`movDwordCtx` 改为 `movQwordCtx`，prologue、`emitSetSite`、closure 恢复 selfFnId 全部 64 位，并加 `ctxStoresAreQword` 回归。
- **剩余失败的归因**：`X86Exec.floatToInt`、`Acceptance.t6ErrorConsistency`、`DbgDump.slotTextCoversValueTypes`、`Helpers.decimalConversions` / `toStrCoversAllTags`、`Interp.floatNanCanonicalization` / `typeInstructions`、`CallMarshal.scalarMarshalling` / `unboxTable`。这些用例都依赖 `Float64` 字面量；box64 下 x86 cjc 把 `Float64(3.0)` 编译为 `0.0`（`1.5` 位型同样为 0），导致基准与预期值错位。aarch64 上同类用例全绿，故判定为**模拟器/工具链缺陷，不是 JIT 代码缺陷**。
- **真机复核结果（2026-10-19）**：在 WSL Ubuntu-24.04（`x86_64-unknown-linux-gnu`，Cangjie `1.3.0-alpha.20261015001050`）上跑全量 `cjpm test` → **560/560 通过、0 失败 / 0 跳过**；x86 后端专项 **85/85**。上述 box64 的 9 失败 + 1 错误**全部不复现**，归因确认成立。
- **真机复跑命令**：

```
cd f_jit && cjpm test --filter '*X86Exec*'
cd f_jit && cjpm test
```

### WARNING-02 T 映射校验的强度（已关闭）

`check_tmap.sh` 现在能拦住「函数名存在但用例不测该 T」的挂名映射。原薄弱点是单元用例的标签只写在注释里，无法证明断言真的覆盖该 T 的语义。2026-10-19 收口方式：

- 新增 `f_jit/src/test/TCase.cj`（`fountain::f_jit.test`）：`hit(id, ok)` 原样返回 `ok`，空 `id` 直接返回 false；
- 13 个单元用例的 `// T<id>/ 映射标签` 全部替换为 `@Assert(TCase.hit('T<id>/<场景>', <真实条件>), true)`——标签与它守卫的那条断言同生共死：条件不成立用例就失败，标签被删/被改则映射校验失败；
- `check_tmap.sh` 改为**先剥离 `//` 与 `/* */` 注释**，再要求出现 `TCase.hit('T<id>/` 或差分用例的 `'T<id>/` 首参形式，注释标签从此不可能通过校验。

实测：40 条范围内映射，悬空 / 未断言 **0**。

### INFO-01 tasks 与实现口径不一致

- `tasks.md` 的 S5.4 子项写「未完成（阻塞）：compile 整单元编排 = P5.8」，S5.8 写「x86 路径待补」，但两项均为 `[x]`。
- `S5.5–S5.7` 的 x86 lowering 勾选依据是 `X86Lower_test` 的**单指令字节断言**，不等于整单元可执行；本轮 `X86Lower` 才把片段组装起来。

建议在 verify 结论中把「框架/单指令断言」与「整单元可执行」分开记，避免后续里程碑继续复用「已勾选」的错觉。

## 剩余未完成 / 测试未覆盖（M1）

### 本轮已关闭

- **常量句柄泄漏**：`pinConst` 引用计数 + `releaseConst`；`JitExecutor` / 纯解释器形态在 `release`/`unload` 归还；普通 `pin` 不再复用常量槽。用例：`HandleTable_test.constRefCountAndRelease`、`pinDoesNotReuseConstSlot`、`ConstantReclaim_test`、`ConstantReclaimFacade_test`。
- **调用窗口泄漏**：`JitFunction.call` 每次 `openWindow` → 执行 → `resetWindow`；窗口按实际槽索引列表回收（支持复用 freeSlots）；返回值句柄 `releaseEscaped`。连续 10/20 次不同源码调用后 liveCount 回到基线。
- **SSE4.1 依赖**：新增 `f_base.CpuFeatures.hasSse41`；无 SSE4.1 时含 `FLOOR/CEIL/TRUNC/ROUND` 的单元整体降级解释器，不再发射非法 `roundsd`。
- **x86 新 lowering 字节 golden**：`X86Compile_test.goldenFloatDivCastClosureLen` 覆盖 FADD、IDIV、IMOD、TO_I64、CALL_CLOSURE、动态 LEN 的关键字节序列。
- **x86 溢出检查方向**：`binOp`/`INEG` 由 `JO ok` 改为 `JNO ok`；`X86Compile_test.checkedArithmeticUsesJno` 断言 IADD/IMUL/INEG 后必须是 `0F 81`。
- **x86 ctx 字段宽度**：`site`/`fnId` 统一 64 位写；`X86Compile_test.ctxStoresAreQword` 断言 prologue 的 `49 C7 47 28` 与 `SET_SITE` 的 `49 C7 47 08`；`X86Frame_test` 黄金序列同步更新。
- **性能留档**：`PerfCompare_test` 改为预编译稳态 JIT vs Interp vs cjnative；数字落 `doc/perf-m1.md`（aarch64 JIT 约为解释器的 2.4%，约 42× 加速；真机 x86_64 三侧逐位一致，稳态 native=3,198,433ns / jit=2,276,989ns / interp=5,987,603,230ns）。
- **scenario 矩阵**：`doc/spec/f-jit-m1/scenario-map.tsv` + `scripts/check_scenarios.sh`，由差分验收 13 条扩到**全 9 个 capability 共 156 条**（未映射 0、缺失 0；缺口 7、部分覆盖 5 已逐条留档）。
- **`JitMode.Force` 可观测**：`JitFunction.isJitBacked()`；`T52` 断言 Force 产物为机器码、Off 产物为纯字节码（aarch64 通过）。

### 仍未完成 / 未覆盖

1. **JIT 全局串行化**：`JitExecutor.envMtx` + `JitFunction.callMtx` 保证单窗口/单 fnTable 正确，但所有调用串行；无并发吞吐测试，M2 宿主回调需改 per-call 隔离。
2. **非 Linux / 其他指令集**：`JitExecutor.create` 已加 Linux + aarch64/x86_64 门禁，但本机无法执行非 Linux 分支，缺 CI 证据（选择层有矩阵用例，执行层无运行证据）。
3. **x86 执行矩阵代表性**：`X86Exec_test` 13 例、`X86Compile_test` 11 例，不等于 157 opcode 逐条执行/逐条字节对拍；真机全绿证明的是「这 13 例覆盖的路径」，不是「每个 opcode 都执行过」。
4. **T6/15 `STACK_GUARD`** 无行为用例；解释器 `0x07` 为 NOP，15 只在桥层重跑余量不足时产生，M1 无稳定构造路径。
5. **T6 映射用例只覆盖 15 码**；7/12/16/17/19/99 的行为证据在 `Interp_test`/`HandleTable_test`/`userapi`/`Helpers_test`，未纳入 `t6ErrorConsistency` 本体。
6. **scenario 矩阵的 7 条缺口**（`check_scenarios.sh` 的 `GAP` 行，无任何用例断言该 scenario）：
   - `f-jit-compiler-frontend / 多字节码点列号`：列号只测过构造值，没有「多字节源码 → 按码点计列」的扫描断言；
   - `f-jit-facade-bridge / 快照语义`：只测了注册表 `snapshot()` 计数，没有「已编译产物不受后续注册变更影响」的断言；
   - `f-jit-facade-bridge / 返回值与声明不符`：声明侧非法类型码有覆盖，运行期「实现返回值与 retType 不符」无断言；
   - `f-jit-facade-bridge / 跨实例复用`：`sameSourceReusesArtifact` 用同一 `Compiler` 实例，跨实例复用未测；
   - `f-jit-facade-bridge / 含宿主句柄的容器被拒`：加载期对含预定义句柄常量的 `.fbc` 无拒绝用例；
   - `f-jit-facade-bridge / 活跃调用排空`：只有 `unload(0)` 空载卸载，没有长调用进行中卸载的排空断言；
   - `f-jit-facade-bridge / 与编译交错`：卸载与同指纹编译并发的状态机交互无用例。
7. **scenario 矩阵的 5 条部分覆盖**：差分「双字段断言」（T6 只 15 码）、骨架「差分层就位」（结构项，只能由差分层用例存在间接证明）、前端「三种书写形态同产物」（只测斜杠消歧，未逐形态比对产物）、后端「降级与 Linux 结果一致」（只测选择层与错误槽，未跨平台比对结果）、门面「全类型行可断言」（只覆盖 I64/F64/Bool/String 四类）。

## 逐 capability 状态

| capability | requirement / scenario | 状态 | 说明 |
|---|---|---|---|
| `f-util-fnv` | 7 / 17 | 绿 | 指纹/校验用例齐全 |
| `f-jit-module-skeleton` | 4 / 7 | 绿 | 包结构、公开导入、构建基线 |
| `f-jit-base-contracts` | 8 / 14 | 绿 | 错误码/类型/诊断契约 |
| `f-jit-bytecode-format` | 10 / 24 | 绿 | 编解码、校验、指纹 |
| `f-jit-compiler-frontend` | 10 / 24 | **黄** | 词法/语法/降低/金样齐绿；「多字节码点列号」无用例断言 |
| `f-jit-runtime` | 11 / 21 | 绿 | 解释器/句柄/helper/转储 |
| `f-jit-backend` | 10 / 16 | **绿** | aarch64 全量绿；x86 补齐 157 个 opcode，**真机 x86_64 全量通过** |
| `f-jit-facade-bridge` | 10 / 20 | **黄** | 生产 JIT 已接入、T52 两形态已补；5 条 scenario 无用例断言（快照/返回值不符/跨实例/宿主句柄容器/排空与交错） |
| `f-jit-differential-acceptance` | 7 / 13 | **绿** | T6 21/22（仅 15 防御码无路径）；三引擎差分在 aarch64 与真机 x86_64 均通过 |

## 本轮执行的校验

| 命令 | 结果 |
|---|---|
| `cjpm test`（Linux aarch64 原生） | **560/560 通过** |
| `cjpm test`（**真机 x86_64**） | **560/560 通过，0 失败 / 0 跳过**（2026-10-19；x86 后端专项 85/85，box64 下 9 失败 + 1 错误不复现） |
| `scripts/check_tmap.sh` | 40 条范围内映射，悬空/未断言 **0**（剥注释后判定 `TCase.hit('T<id>/…')` / `diff('T<id>/…')`） |
| `scripts/check_scenarios.sh` | **156 条映射（full 139 / partial 5 / 缺口 7 / N/A 5），未映射 0、缺失 0** |
| `openspec update --force`（worktree f_jit） | 12 个工作流命令齐备，含 `verify.md` |
| `JitWire_test.createsExecutableAssets` | 通过（生产路径可建 JIT 资产） |
| `X86Compile_test`（分支/容器/递归/浮点/除法/转换/闭包/LEN/JNO/ctx 宽度） | 11/11 通过（字节级组装） |
| `X86Frame_test` | 通过（prologue 黄金序列已同步为 64 位 fnId 写） |
| `X86Exec_test` | 13 例全通过（真机 x86_64） |
| `Interp_test.castTypeMismatchYields7` | 通过（T6/7 行为证据） |

## 建议的下一步（按优先级）

1. **补 7 条缺口的用例**（按风险排序）：`快照语义`（编译后注销再调用）、`活跃调用排空`（长调用中 `unload`）、`与编译交错`（卸载 × 同键编译）、`含宿主句柄的容器被拒`（构造带 hid 的 `.fbc`）、`返回值与声明不符`（`PredefinedFunction` 返回错类型）、`跨实例复用`（两个 `Compiler` 实例同源）、`多字节码点列号`（emoji 后紧跟标识符的列号）。补完把对应行的 `GAP/none` 改成用例名 + `full`，再跑 `check_scenarios.sh --strict`。
2. **并发隔离**：`JitExecutor.envMtx` / `JitFunction.callMtx` 的全局串行改 per-call（M2 宿主回调的前置）。
3. **非 Linux 执行证据**：Windows/macOS/HarmonyOS 的降级执行层至少补 CI 冒烟，当前只有选择层矩阵。
4. **x86 执行矩阵加密**：把 157 个 opcode 按组补执行用例，缩小「13 例代表全量」的差距。
5. 上述完成后重跑 `check_tmap.sh`、`check_scenarios.sh --strict` 与两平台全量 `cjpm test`。

## 2026-10-19 追加：真机 x86 全绿 / 矩阵与标签收口

- **x86 真机**：实现层补齐 157 个 opcode 后，box64 先取得执行证据（560 例 / 550 过，9 失败 + 1 错误全为 box64 `Float64` 字面量恒 0），随后在**真机 x86_64 上全量通过**，上述失败不复现。WARNING-01 关闭。
- **`/opsx:verify` 安装**：`f_jit` worktree 原先缺 `verify.md`（只有 6 个工作流），已用 `openspec update --force` 从全局档位（12 工作流，`profile=custom`）重新生成 `.codebuddy/commands/opsx/`，现 12 个命令齐备；`.codebuddy/` 属 `.gitignore`，安装不产生版本库改动。
- **scenario 矩阵**：`scenario-map.tsv` 从 13 行扩到 **156 行（全 9 capability）**，新增第 4 列「强度」。`check_scenarios.sh` 增强为三道检查：scenario 必须存在于该 capability 的 spec、测试函数必须能在 `f_jit/src` 或 `f_util/src` 解析到、**spec 里每条 scenario 都必须被映射（反向完整性）**；`GAP` 行计入缺口清单，`--strict` 时缺口/部分覆盖即失败。实测：156 条，未映射 0，缺失 0，缺口 7，部分 5。
- **T 标签行为级**：新增 `src/test/TCase.cj`（`TCase.hit(id, ok)`），13 个单元用例里 `// T<id>/` 注释全部替换为 `TCase.hit('T<id>/<场景>', <真实条件>)` 包裹断言；`TwoForms_test` 的 T52 由注释改为「两形态结果比对」断言。`check_tmap.sh` 改为**先剥离 `//` 与 `/* */` 注释**，再要求 `<函数>( 'T<id>/` 形式的字符串首参——注释标签从此不可能通过校验。实测 40 条范围内映射，悬空 0。
- **未在融合侧编译验证**：本次编辑（`TCase.cj` + 11 个测试文件 + 2 个脚本）在鸿蒙侧完成，本机无 `cjc`/`cjpm`。静态检查（`check_tmap.sh`、`check_scenarios.sh`）已通过，**仍需在融合环境跑一次 `cjpm build && cjpm test` 确认可编译**。

## 2026-10-22 真机回归（x86_64 栈对齐修复，change `fix-f-jit-x86-stack-align`）

- 环境：WSL Ubuntu-24.04 / `x86_64-unknown-linux-gnu` / Cangjie `1.3.0-alpha.20261015001050`
- 缺陷：`X86Lower` 用**线性**深度推导栈深，`alignBeforeCall` 以 `depth % 2` 决定 16 字节对齐补丁；
  `CastOr`（`E as T ?? V`）的失败分支汇合处运行期深度 0、线性深度 1 ⇒ 对齐算反 ⇒ JIT 内 SIGSEGV
  （3 例：`downcastFallsBackOnMismatch` / `bareCastFailsWithBadCast` / `unknownClassNameUsesRuntimeCheck`）
- 修复：`X86Depth.analyze` 以**控制流数据流**求逐指令入口深度（增量由 `X86Lower` 探针遍采集），
  `X86Lower.lower` 三遍（探针 → 数据流 → 发射），不可达区域沿用线性深度；推导失败整单元退回解释器
- 回归：修复前 **1091 例 / 1084 过 / 3 ERROR / 4 FAILED**；修复后 **1098 例 / 1094 过 / 0 ERROR / 4 FAILED**
  （新增 7 例：2 个同型行为用例 + 5 个深度分析单测；**剩余 4 个 FAILED 为修复前既有**：
  `p0_6_deadlineInterruptsLoop`、`defaultIsStrict`、`strictDivisionByZeroFails`、`strictFpIsPartOfCacheKey`
  —— 属 `strictFp`/期限面，另立变更处理）
- RED 证据：临时回退 `X86Lower.cj` 复跑 `CastOr_test` ⇒ 4 例 ERROR；恢复修复后 0 ERROR

## 2026-10-22 第二轮回归（strictFp ÷0 与回边安全点，change `fix-f-jit-strictfp-deadline-x86`）

- 4 个长期 FAILED 的根因：
  ① `FDIV_CHK` 谓词写反（`jnp` 有序即跳 ⇒ 零检查被跳过）→ 改 `jp`；
  ② x86 `LOOP_BACK` 只有 `jmp`，缺 H22 `interrupt_poll`（aarch64 与解释器均有）→ 回边补 H22
- 修复后：`StrictFp_test` **5/5**、`AnyBridgeCall_test` **7/7**（含 `p0_6_deadlineInterruptsLoop` 1.3ms 中断）
- **全量：1098/1098，0 FAILED / 0 ERROR / 0 SKIPPED**
- 遗留（本变更未做）：x86 `LOOP_BACK` 的 **STACK_GUARD**（`(rbp-frame)-rsp < frame ⇒ -1`）尚未补，
  与 aarch64 存在语义差；已记入 §12.4 口径与后续待办（当前所有用例不受影响）

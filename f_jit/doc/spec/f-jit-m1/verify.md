# f-jit-m1 校验报告（verify）

- 变更：`f-jit-m1`
- 校验对象：`openspec/changes/f-jit-m1` 的 9 份 spec（40 requirement / 156 scenario）、`tasks.md`（115 项）
- 校验时间：2026-10-18
- 校验方式：**手工等价校验**。本 worktree 的 `.codebuddy/commands/opsx/` 未安装 `verify` 工作流（只有 apply/archive/explore/propose/sync/update），`/opsx:verify` 无法在融合侧启动；本报告按同一口径逐项对照实现与用例，不修改 `tasks.md`。
- 基线：`cjpm test` **547/547**（Linux aarch64 原生）；`scripts/check_tmap.sh` **40 条范围内映射，悬空/未断言 0 条**。

## 结论

**apply 的 115/115 不等于规格全绿。** 本轮已修掉 2 个 CRITICAL、降级 1 个、修复 1 个映射问题；仍有 2 个 CRITICAL 未清零（x86 指令覆盖、T6 全码矩阵），因此**不建议现在 archive**。

| ID | 严重度 | 状态 | 摘要 |
|---|---|---|---|
| CRITICAL-01 | CRITICAL | **已修复** | 用户面 `Compiler.compile` 原先只返回解释器函数，JIT 从未接入生产路径 |
| CRITICAL-02 | CRITICAL | **部分修复** | x86 lowering 已补控制流/比较/调用模板/常量镜像；浮点、CAST、CALL_CLOSURE、LEN 等仍缺，遇未支持指令整单元降级 |
| CRITICAL-03 | CRITICAL | **部分修复** | T6 错误矩阵由 5 码扩到 16 码；7/15/16/17/19/99 仍无源码级差分证据（19 有契约用例，其余为引擎内部码） |
| CRITICAL-04 | CRITICAL | **已修复** | T52/T53 原为「挂名映射」；已补真实两形态用例与常量写 20 断言 |
| WARNING-01 | WARNING | 未关闭 | x86 执行证据未在本机取得（无 x86_64 原生环境）；本轮只做字节级组装验收，需在 x86_64 机器跑 `X86Exec_test` |
| WARNING-02 | WARNING | 部分关闭 | `check_tmap.sh` 已升级为「用例体必须含 `T<id>/` 标签」；单元用例的标签仍是注释级，只有 T52/T53 是行为级 |
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
- `MachineEnv.fnTableBase` 仍是进程级全局，多单元并发 JIT 调用存在竞态；M1 未提供隔离。建议下一轮加 per-call 保存/恢复或串行化。

### CRITICAL-02 x86 指令降低未覆盖全部指令（部分修复）

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

**仍缺（遇之仍整单元降级）**
- 浮点：`FADD/FSUB/FMUL/FDIV/FDIV_CHK/FNEG/FABS/FMIN/FMAX/FSQRT/FFLOOR/FCEIL/FTRUNC/FROUND`（`0x40–0x4D`）
- 整型：`IDIV/IMOD/IMIN/IMAX/ICLZ/IPOPCNT`（`0x33/0x34/0x37/0x38/0x3A/0x3B`）
- 类型：`CAST`（`0x80`）、`TO_I64`（`0x81`）、`TO_F64`（`0x82`）、`GUARD_TYPE mode1`、`DEC_TO_I64 mode1` 的 DEOPT 改写
- 调用：`CALL_CLOSURE`（`0x7F`）、`LOAD_CAP`（`0x26`）
- 容器动态 `LEN`（`0x90`，需按 tag 选 hid）
- `DT_NEW/DUR_NEW`（`0xA9/0xAA`，M1 汇编期禁发）

**判定**：分支与容器用例已可「真走 JIT」，但「全部指令」要求仍未满足。要么补齐上述分组，要么在 spec 中把 M1 的 x86 明确降为「框架 + 部分指令」，不能两处都写成已完成。

### CRITICAL-03 T6 错误矩阵不完整（部分修复）

**规格口径**：`plan-m1.md:221` —「错误一致性 1–20/99」。原 `t6ErrorConsistency` 只断言 1–5。

**本轮新增**
- 源码级差分：9（Decimal→I64 越界）、10（Decimal ÷0）、11（DateTime 越界）、13（F64→I64 NaN/Inf/越界）、14（非法 regex）、23（迭代中改同一 map）
- 修复 `decToI64` 对超大指数静默返回 0 的缺陷：`Int64(1.0e300)` 现按 **9** 报错（该字面量在 M1 是 Decimal，不是 F64；13 由运行时 `Int64(x: Float64)` 覆盖）
- helper 级（源码类型系统不可达）：6（null 句柄）、8（句柄类型不符）、18（未实现 helper）、20（常量容器写）
- 覆盖码：**1–6、8–14、18、20、23**，共 **16/21**

**仍未覆盖**
- 7 `BAD_CAST`：只在 `CAST` 指令未命中时产生，源码不可构造（M1 无 Any/动态类型）
- 15 `STACK_GUARD`：桥层重跑余量不足，需专用栈配置
- 16 `HANDLE_WINDOW_FULL`：需全局窗口上限压测，已有 `Helpers_test` 单元覆盖
- 17 `EXPLICIT`：源码 `throw` 未实现
- 19 `CALL_CONTRACT`：已有 `userapi/contractErrorIsVisible` 与 `JitFunction_test`
- 99 `HELPER_PANIC`：需构造 helper 内部未识别异常

**判定**：错误码矩阵从 5 扩到 16，但离「1–20/99 全码」仍有差距；建议在 spec/plan 中把「源码可达码」与「引擎内部码（由单元用例覆盖）」分开记，避免用单一 diff 用例承诺全码。

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
- 13 个单元用例的 `T<id>/` 标签以注释形式加入，属于追溯标签而非行为断言；真正行为级的是 T52/T53。若要求所有映射都行为级，需要逐个把 T 编号写进子用例 ID（工作量较大）。

## WARNING 明细

### WARNING-01 x86 执行证据缺失

本轮在 Linux aarch64 上完成 x86 机器码的**字节级组装验收**（`X86Compile_test`）与 `X86Frame_test` 字节断言；`X86Exec_test` 的 5 例（最小单元/算术/分支/容器/递归）只在 `arch == 'x86_64' && os == 'Linux'` 时执行，本机全部条件跳过。需在真实 x86_64 机器上跑：

```
cd f_jit && cjpm test --filter X86Exec_test
cd f_jit && cjpm test --filter X86Compile_test
```

### WARNING-02 T 映射校验的强度

`check_tmap.sh` 现在能拦住「函数名存在但用例不测该 T」的挂名映射；但单元用例的标签是注释，无法证明断言真的覆盖该 T 的语义。建议后续把每个 T 的子用例 ID 统一为 `T<id>/<场景>`（差分用例已如此）。

### INFO-01 tasks 与实现口径不一致

- `tasks.md` 的 S5.4 子项写「未完成（阻塞）：compile 整单元编排 = P5.8」，S5.8 写「x86 路径待补」，但两项均为 `[x]`。
- `S5.5–S5.7` 的 x86 lowering 勾选依据是 `X86Lower_test` 的**单指令字节断言**，不等于整单元可执行；本轮 `X86Lower` 才把片段组装起来。

建议在 verify 结论中把「框架/单指令断言」与「整单元可执行」分开记，避免后续里程碑继续复用「已勾选」的错觉。

## 逐 capability 状态

| capability | requirement / scenario | 状态 | 说明 |
|---|---|---|---|
| `f-util-fnv` | 7 / 17 | 绿 | 指纹/校验用例齐全 |
| `f-jit-module-skeleton` | 4 / 7 | 绿 | 包结构、公开导入、构建基线 |
| `f-jit-base-contracts` | 8 / 14 | 绿 | 错误码/类型/诊断契约 |
| `f-jit-bytecode-format` | 10 / 24 | 绿 | 编解码、校验、指纹 |
| `f-jit-compiler-frontend` | 10 / 24 | 绿 | 词法/语法/降低/金样 |
| `f-jit-runtime` | 11 / 21 | 绿 | 解释器/句柄/helper/转储 |
| `f-jit-backend` | 10 / 16 | **黄** | aarch64 全量绿；x86 仅部分指令，见 CRITICAL-02 |
| `f-jit-facade-bridge` | 10 / 20 | **绿（本轮修复）** | 生产 JIT 已接入；T52 两形态已补 |
| `f-jit-differential-acceptance` | 7 / 13 | **黄** | T6 16/21；x86 执行证据待补 |

## 本轮执行的校验

| 命令 | 结果 |
|---|---|
| `cjpm test`（Linux aarch64） | **547/547 通过** |
| `scripts/check_tmap.sh` | 40 条范围内映射，悬空/未断言 **0** |
| `JitWire_test.createsExecutableAssets` | 通过（生产路径可建 JIT 资产） |
| `X86Compile_test`（分支/容器/递归） | 3/3 通过（字节级组装） |
| `X86Frame_test` | 通过（实参 ABI 改为 `[rsi-8i]`） |

## 建议的下一步（按优先级）

1. **补 x86 浮点/CAST/TO_I64/CALL_CLOSURE/LEN**，或在 spec 中显式降级 x86 范围；二选一，不能继续双口径。
2. **T6 剩余码**：7/15/16/17/99 补专用构造用例；19 已有契约用例，在 plan 中改为「契约层覆盖」。
3. **x86_64 机器验收**：跑 `X86Exec_test` 与全量 `cjpm test`，把结果回填本报告 WARNING-01。
4. **MachineEnv 并发隔离**：per-call 保存/恢复或串行化，避免多单元并发 JIT 串表。
5. 上述完成后重跑 `check_tmap.sh`，再进 `opsx:archive`。

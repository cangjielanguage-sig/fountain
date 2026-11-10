# Verify（fix-jit-unary-not / N5.1）

> 变更：修 AArch64 `NOT_B` 的 `Rn` 位域（`0xD2400009` → `0xD2400129`），并把 `!`
> 按操作数类型分派（Bool → `NOT_B`、Int64 → `BNOT_I`、其余编译期报错）。
> 本文件只记录可复跑的判据与原始输出，不复述 design。

## 1 全量回归

| 项 | 数值 |
| --- | --- |
| 基线（N0.1，修复前） | **1145 用例 / 1145 通过 / 0 失败 / 0 error / 0 skipped**（`cjpm test` 4 m 42 s；`cjpm build` 2 m 59 s） |
| 终态（N3.3，修复后） | **1163 用例 / 1163 通过 / 0 失败 / 0 error / 0 skipped**（1 m 09 s） |
| 新增用例 | 18 条（`UnaryNotDiff_test` 10 + `UnaryNotShape_test` 6 + `A64NotBEncoding_test` 2） |
| 回归 | 0（既有 1145 条全部保持通过） |

复现命令（融合侧，`f_jit` 模块目录下）：

```bash
source /tmp/cjenv.sh   # STDX / LIBRARY_PATH 修正，见 module 内既有环境说明
cjpm build && cjpm test
# 只跑本变更的三组用例（`--filter` 需带尾随 `*`）：
cjpm test --filter "UnaryNot*" --no-capture-output
cjpm test --filter "A64NotBEncoding*" --no-capture-output
```

## 2 报障用例的前后原始输出（`{ n: Int64 => !(n < 50) }`，`n = 49`）

| 观测点 | 修复前 | 修复后 |
| --- | --- | --- |
| `InterpRunner`（语义基准） | `0` | `0` |
| AArch64 原始 cell（`AArch64Runner` 对 Bool 返回按 i64 文本化） | `281471889967937` = `x0(ctx) \| 1` | `0` |
| 桥 `Compiler().compile(src).call<Bool>([49])` | `true` | `false` |

修复前 AArch64 产物中 `0x5E` 的三字（N0.2 / N1.2 原始抽取）：

```
890240f9   ldr x9,[x20]
090040d2   eor x9,x0,#1     ← Rn = 0，与注释 `eor x9,x9,#1` 不符
890200f9   str x9,[x20]
```

修复后：

```
890240f9   ldr x9,[x20]
290140d2   eor x9,x9,#1     ← Rn = Rd = 9
890200f9   str x9,[x20]
```

对应断言：`A64NotBEncoding_test.notBLowersToEorWithRnAndRdEqualNine`
（红态报 `0xD2400009 != 0xD2400129`）；语义断言：`UnaryNotDiff_test.reportedCase`
（红态报 `result: 0 != 281471889967937`）。

## 3 分层判据（红态复现记录）

| 层 | 用例 | 修复前 | 修复后 |
| --- | --- | --- | --- |
| S1 AST | `UnaryNotShape_test.astShapeOfReportedCase` | 绿（`(! (< var(n) lit(50)))`） | 绿 |
| S2 字节码 | `UnaryNotShape_test.bytecodeShapeOfReportedCase` | 绿（`LOADL PUSH_I64 LT_I NOT_B RET`） | 绿 |
| S4/S5 编码 | `A64NotBEncoding_test.notBLowersToEorWithRnAndRdEqualNine` | **红**（`0xD2400009`） | 绿 |
| S4 编码原语 | `A64NotBEncoding_test.eorImm1PutsRnAndRdInTheirOwnFields` | 函数未落地（N2.1 起） | 绿（`290140D2` / `090040D2`） |
| S3 语义 | `UnaryNotDiff_test`（10 条） | **红** 8 条 / 绿 2 条 | 全绿 |

修复前 `UnaryNotDiff_test` 的 8 条红：`reportedCase` / `comparisonBoundary` /
`comparisonExtremes` / `comparisonFamily` / `booleanArgument` / `doubleNegation` /
`logicalCombination` / `bitwiseNotOnInt64`。另 2 条 `noNotControl`、`regexNotMatch`
修复前后都为绿——前者是没有 `!` 的对照，后者见 §6 第 4 条。

非 Bool 分支的红态指纹（`bitwiseNotOnInt64`，N1.5）：

```
N/bnot-2: 解释器绝对值不符 —— 期望 -3，实得 0；原生后端实得 2814718899…
```

## 4 x86 证据（已补齐，2026-10-31）

**执行环境**（原生 x86_64 Linux，WSL2）：

```
Linux LAPTOP-U0CFCO9P 6.18.54.1-microsoft-standard-WSL2 #1 SMP PREEMPT_DYNAMIC Tue Oct  6 19:13:07 UTC 2026 x86_64 x86_64 x86_64 GNU/Linux
Cangjie Compiler: 1.3.0-alpha.20261015001050 (cjnative)
Target: x86_64-unknown-linux-gnu
```

**代码基线**：`sts/1.3.x@05d0ed6f`（已含 `fix-jit-unary-not` 的 `f5498e55`；工作树 `.worktrees/f_jit`）。

**全量结果**（`cjpm test`，`f_jit` 模块）：

| 运行 | 汇总 |
|---|---|
| 1 | TOTAL 1171 / **PASSED 1171** / FAILED 0 / SKIPPED 0 |
| 2（抓明细） | TOTAL 1171 / PASSED 1170 / FAILED 1 —— 唯一失败为 `PerfOverride_test.overrideBeatsReflectionEndToEnd`（`PERF-OVERRIDE 净成本未达标 ref=12165ns ov=18665ns`），属性能阈值抖动、与 `!` 无关；同批第 1 次全绿 |

**`!` 矩阵（两次全量中均绿）**：

| 测试类 | x86_64 结果 |
|---|---|
| `UnaryNotDiff_test` | **10/10 绿**：`bitwiseNotOnInt64`（`!2=-3`、`!0=-1`、`!-1=0`、`Int64.max/min` 位反）、`booleanArgument`（`!true=false`）、`doubleNegation`、`logicalCombination`、`regexNotMatch`、`comparisonFamily/Boundary/Extremes`、`noNotControl`、`reportedCase` |
| `A64NotBEncoding_test` | 2/2 绿（纯编码断言，与宿主架构无关） |
| `UnaryNotShape_test` | 6/6 绿（`int64OperandLowersToBitNot`、`boolOperandLowersToLogicalNot`、`nonBoolNonIntOperandIsRejected`、`astShapeOfReportedCase`、`bytecodeShapeOfReportedCase`、`bytecodeShapeOfRegexNegation`） |

**引擎参与判据**：`UnaryNotDiff_test` 先要求 `outs.size >= 2`（否则 `@Fail('可用引擎只有 N 个')`）、再断言 `session.ran() >= 1`；10 条全绿 ⇒ x86 主机上 `NativeRunner` 被条件编译为 `BackendX86_64` 并**真实参与**差分，`!` 在 x86 机器码上的语义与本机（AArch64）结论一致。

**验收项订正**：原「跳过统计里出现 `BackendX86_64`」在 x86 主机上不适用——`skipped()` 计的是「注册了但不可用」的 runner，x86 上两个 runner 都可用，故 `SKIPPED = 0`。N3.4 的实际判据改为「x86 主机上 `UnaryNotDiff_test` 全绿且未出现『可用引擎只有 1 个』失败」，本次已满足。

**本机（aarch64）侧记录保持原样**：`DiffSession([InterpRunner(), NativeRunner()])` 只注册 `Interp × AArch64`，跳过数为 0、不产生 `BackendX86_64` 条目。x86 静态编码（`48 83 34 24 01` = `xor qword [rsp],1`）本次未改动，N0.3 抽样已核对其字节正确。

## 5 N4.1 同段抽样审计（`0x50–0x6E`）

方法：对每个 opcode 编一个最小单元（两份 `PUSH_BOOL 1` + 目标 op + `RET`），把产物逐字
按位域解码，与「按 ARM64 编码规则重建的期望字」逐条对拍。探针为一次性脚本，已删除；
下表是当次输出的人工核对结果。

| opcode | 关键指令 | 现字 | 期望字 | 结论 |
| --- | --- | --- | --- | --- |
| `0x50` `CMP_I` | `cmp x9,x10` | `0xEB0A013F` | `0xEB0A013F`（`Rn=9, Rm=10, Rd=31`） | 编码正确 |
| | `cset x11,lt` | `0x9A9FA7EB` | `0x9A9FA7EB` | 编码正确 |
| | `cset x10,gt` / `sub x9,x11,x10` | `0x9A9FD7EA` | `0x9A9FD7EA` | **符号约定与解释器相反 → 登记 B7** |
| `0x51` `CMP_F` | `fcmp d1,d0` | `0x1E602020` | `0x1E602020` | 编码正确；**同 B7** |
| `0x52` `EQ_I` | `cset x9,<inverted EQ>` | `0x9A9F17E9` | `0x9A9F17E9` | 编码正确 |
| `0x53` `NE_I` | `cset x9,<inverted NE>` | `0x9A9F07E9` | `0x9A9F07E9` | 编码正确 |
| `0x54` `LT_I` | `cset x9,<inverted LT>` | `0x9A9FA7E9` | `0x9A9FA7E9` | 编码正确 |
| `0x5E` `NOT_B` | `ldr x9,[x20]` | `0xF9400289` | `0xF9400289` | 编码正确 |
| | `eor x9,x9,#1` | `0xD2400129` | `0xD2400129` | **本次修复对象** |
| | `str x9,[x20]` | `0xF9000289` | `0xF9000289` | 编码正确 |
| `0x5F` `AND_B` | `and x9,x9,x10` | `0x8A0A0129` | `0x8A0A0129` | 编码正确 |
| `0x60` `OR_B` | `orr x9,x9,x10` | `0xAA0A0129` | `0xAA0A0129` | 编码正确 |
| `0x61` `XOR_B` | `eor x9,x9,x10` | `0xCA0A0129` | `0xCA0A0129` | 编码正确 |
| `0x62–0x64` | 同上三条（`bitBin` 复用 `boolBin`） | 同上 | 同上 | 编码正确 |
| `0x65` `BNOT_I` | `mvn x9,x9`（`ORN x9,xzr,x9`） | `0xAA2903E9` | `0xAA2903E9` | 编码正确 |
| `0x66` `SHL_I` | `lslv x9,x9,x10` | `0x9ACA2129` | `0x9ACA2129` | 编码正确 |
| `0x67` `SHR_I` | `asrv x9,x9,x10` | `0x9ACA2929` | `0x9ACA2929` | 编码正确 |
| `0x68` `USHR_I` | `lsrv x9,x9,x10` | `0x9ACA2529` | `0x9ACA2529` | 编码正确 |
| `0x69/0x6A` `EQ_H/NE_H` | `cmp x9,x10` + `cset` | `0xEB0A013F` / `0x9A9F17E9`(EQ)、`0x9A9F07E9`(NE) | 同 | 编码正确 |
| `0x6B–0x6E` | `mov x1,x19` / `&args` / `str x0,[x20,#8]` | `0xAA1303E1` / `0x91002282` / `0xF9000680` | 同 | 编码正确 |

**结论**：`Rn`/`Rd`/`Rm`/`imm` 字段在 `0x5E` 之外**未发现**同类错编码；唯一发现的
同族问题是 `CMP_I`/`CMP_F` 的三向比较符号约定（B7），按其「只登记不改」处置。

### B7（本次登记，不修，另立变更）

- **现象**：`Interp` 的 `CMP_I`/`CMP_F` 定义为 `a < b → -1`、`a > b → +1`
  （`Interp.cj:498` / `:501`），而 x86（`BackendSelector.cj:1498` 的 `emitCmpI`：
  `setl - setg`）与 A64（`A64Lower.intCmpI`：`cset lt; cset gt; sub`）都是
  `a < b → +1`、`a > b → -1`——符号相反。
- **可达性**：`Op.CMP_I` / `Op.CMP_F` 目前**没有 Lowerer 生产者**（`Lowerer` 只发
  `LT_I` 等单条件比较），因此该分歧现在不可达，`0x50` 的三字用例是唯一入口。
- **附带**：`design-m1.md` / `jit-bytecode-m1.md` 该行写 `cset x11,lt; cset x12,gt;
  sub x11,x12`，寄存器与实现（`x11`/`x10`/`x9`）也不一致——与 B7 同批订正。
- **处置**：按 design §3.4「不重排 `0x50–0x6E` 整段」，本次只登记；修复需同时决定
  「以解释器为规范」还是「以降级产物为准」，并补三引擎对拍用例。

## 6 与 design 的偏差（实施期发现，均为「验收表达」而非架构决策）

1. **design §4.2 两处算术笔误**：`!(!=)` 在 `n = 5` 上 `5 != 5` 为假，取反得 `1`
   而非表中 `0`；`!(a || b)` 的 `(true,false)` 取反得 `0` 而非 `1`。
   用例改为「使比较成立」的入参（`n = 4`）与正确真值（`0`），断言口径不变。
2. **`AstShape.exprOf` 的入参是 lambda 源**（内部走 `Parser.parseLambda`），
   故 S1 写成 `AstShape.exprOf('{ n: Int64 => !(n < 50) }')`，形状文本仍取自尾表达式。
3. **`!~` 用例改用源码内字面量**：`DiffCase.args` 的 cell 装箱只认
   `Int64 / Float64 / Bool`（`RealRunners.cells`），String 会被填 0（空指针）。
4. **`!~` 在修复前就是绿的**：`{ => /abc/ !~ "x" }` 含 `REGEX_IS_MATCH` 调用，helper
   返回后 `x0` 恰好是真值，`eor x0,#1` 碰巧等价。这说明「有 helper 的函数体」不暴露
   本缺陷，缺陷只在无 helper 的函数体（`x0 = ctx`）暴露——与 design §1 的 S6 一致，
   但不构成「`!~` 已被覆盖」的证明：真正的覆盖来自 `{ n: Int64 => ... }` 的矩阵。
5. **A64 编码用例不在 `SourceCompiler` 链路上**：`fountain::f_jit.compiler` 依赖
   `backend`，反向引用会构成包级循环依赖；`A64NotBEncoding_test` 改为手工装配
   `PUSH_BOOL 1 / NOT_B / RET` 的最小 `LoadedUnit`，语义等价且不引入循环。

## 7 判据索引

| design / tasks 判据 | 可执行用例 |
| --- | --- |
| `!(n < 50)` 在 49 上为 `0` | `UnaryNotDiff_test.reportedCase` |
| 边界 / 极值 / 比较族 | `comparisonBoundary` / `comparisonExtremes` / `comparisonFamily` |
| `!true = false` | `booleanArgument` |
| 双重取反 / 逻辑组合 | `doubleNegation` / `logicalCombination` |
| `!~` 的 `NOT_B` 恰一条 | `regexNotMatch` / `bytecodeShapeOfRegexNegation` |
| 无 `!` 对照逐位不变 | `noNotControl` |
| `!2 = -3` 等 Int64 位反 | `bitwiseNotOnInt64` |
| 类型分派（Bool/Int64/其余） | `int64OperandLowersToBitNot` / `boolOperandLowersToLogicalNot` / `nonBoolNonIntOperandIsRejected` |
| 编码 `0xD2400129` + `Rn=Rd=9` | `notBLowersToEorWithRnAndRdEqualNine` |
| `eorImm1` 字段位域 | `eorImm1PutsRnAndRdInTheirOwnFields` |
| AST / 字节码形状 | `astShapeOfReportedCase` / `bytecodeShapeOfReportedCase` |

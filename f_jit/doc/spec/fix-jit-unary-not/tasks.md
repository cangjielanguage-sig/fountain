# Tasks

> 编号前缀 `N`（Not），与 A（Audit）/ R（M3）/ Q（M2）/ S（M1）不复用。
> **严格 TDD**：先写会失败的用例（红）→ 确认红 → 最小实现（绿）→ 重构；用例由红转绿才勾选。
> **每批末验收**：`f_jit` 模块内 `cjpm build` 通过、新增用例全绿、既有全量（含差分最小集）零回归、失败数 0。
> **假绿禁令**：编码/形状用例属结构断言，只用于定位分层，不得替代语义用例的验收地位。
> **分支**：`fix/jit-unary-not`（不在 master 上直接改）。

## N0 基线与复现

- [ ] N0.1 基线：跑既有全量（含差分最小集 `Interp × AArch64`），记录用例数 / 通过 / 失败 / 耗时，作为后续每批对照。验收：数字留档（本变更只允许新增用例数上升，既有用例不得由绿转红）。
- [ ] N0.2 复现留证：用 `SourceCompiler(PredefinedSnapshot.empty(), DummyDiagnosticsSink(), strictFp: false).compile('{ n: Int64 => !(n < 50) }')` 编出同一份 `.fbc`，先以 `A64Exec_test.run` 取**原始 cell**（不看桥的解包），再以 `InterpRunner` / `NativeRunner` 各跑一次 `n = 49`。验收：留档「解释器 `0` / A64 原始 cell 为巨大非零 / 桥侧 `true`」三段原始输出，作为修复前的失败指纹；若 A64 原始 cell 不是「巨大非零」（例如恰为 `2`），先停下来复检 design §1 的 `x0 = ctx` 前提，不得直接改码。
- [ ] N0.3 三条已证伪候选的复核留档：`AstShape.exprOf('!(n < 50)')`、`CodeDump.dump(cu.raw)`、`X86Lower` 的 `48 83 34 24 01`。验收：三者与 design §2.1 的 S1/S2 表一致，避免实施时重开已排除项。

## N1 先写红（不改实现）

- [ ] N1.1 语义红：新增 `f_jit/src/compiler/UnaryNotDiff_test.cj`，按 design §4.2 的矩阵逐条落例；每条**同时**断言「解释器结果 = 绝对值」与「`DiffSession([InterpRunner(), NativeRunner()]).assertTripleEqual` 通过」，并断言 `session.ran() >= 1`。验收：`n = 49` 一例在 AArch64 上必红，失败信息里能同时看到解释器 `0` 与后端异常值。
- [ ] N1.2 编码红：新增 `f_jit/src/backend/A64NotBEncoding_test.cj`，只用现有 API——用 `A64Compiler.compileFunction` 编 `PUSH_BOOL 1; NOT_B; RET` 的最小单元，在产物里定位 `0x5E` 的三字，断言 `ldr x9,[x20]` / `0xD2400129` / `str x9,[x20]`、解码 `Rn == Rd == 9`、产物中不出现 `0xD2400009`。验收：红态是**断言红**（报到错误字 `0xD2400009`），不是编译红；`eorImm1` 的 hex 断言留到 N2.1 落函数时一起加，避免为编过测试先埋桩。
- [ ] N1.3 形状用例：新增 `f_jit/src/compiler/UnaryNotShape_test.cj`——AST 形态、`!(n<50)` 的字节码 `LOADL; PUSH_I64 50; LT_I; NOT_B; RET`、`re !~ s` 的 `NOT_B` 恰一条。验收：本组**应直接绿**（前端本来就对）；它红说明根因另有其处，须回到 design §2 重新定位，不得继续按 N2 改码。
- [ ] N1.4 红态确认：三组用例各跑一次并留档输出。验收：N1.1 / N1.2 红、N1.3 绿；结论与 design §1 一致。

## N2 最小实现

- [ ] N2.1 `A64Emitter.eorImm1(rd, rn)`：`word(0xD2400000u32 | (UInt32(rn) << 5) | UInt32(rd))`，注释标明 `EOR Xd, Xn, #1`（`N=1, immr=0, imms=0`）。验收：`eorImm1(9, 9)` 的 hex 为 `290140D2`，且 `eorImm1(9, 0)` 为 `090040D2`（反向固定位域，防止把 `Rn`/`Rd` 又写反）。
- [ ] N2.2 换调用点：`A64Lower.cj` 的 `case 0x5E` 改调 `this.e.eorImm1(9, 9)`，删除裸字面量与「x9,x9」的注释。验收：`0x5E` 分支内不再出现任何 `0xD2…` 字面量。
- [ ] N2.3 只碰这两处：确认 diff 仅涉及 `A64Emitter.cj` 与 `A64Lower.cj`（外加测试文件）。验收：`git diff --stat` 无第三处实现文件；若被迫改动解码器/帧/深度，先回 design §2 复核定位。

## N3 转绿与回归

- [ ] N3.1 新增用例全绿：N1.1–N1.3 三组全通过。验收：`!` 全部矩阵在 AArch64 与解释器上逐位一致，`n = 49` 为 `0`。
- [ ] N3.2 无 `!` 对照：`{ n: Int64 => n < 50 }` 在 49 / 50 上仍为 `1 / 0`，与修复前逐位相同。验收：比较语义零变化。
- [ ] N3.3 全量零回归：跑既有全量（M1–M3 含差分最小集），用例数与 N0.1 对照，任何既有用例由绿转红按阻塞缺陷处理。验收：失败数 0。
- [ ] N3.4 x86 证据：在原生 x86_64 主机（或 CI 矩阵）跑同一 `UnaryNotDiff_test`，确认 x86 与本机结论一致（修复前后都应绿，因为 x86 本来就对）；AArch64 主机上留档「x86 跳过 / 无证据」。验收：跳过统计里出现 `BackendX86_64` 且不计通过。

## N4 加固与文档

- [ ] N4.1 同段抽样审计（结构）：对 `0x50–0x6E` 各编译一个最小单元，把 `A64Lower` 的产物与「按位域重建的期望字」逐条对拍，重点看 `EOR/AND/ORR/CMP/CSET/LSL/LSR/ASR` 的 `Rn`/`Rd`/`imm` 字段。验收：输出一张「指令 → 现字 → 期望字 → 结论」表；发现的同类错编码**只登记不改**，另立变更（守住本变更的修复面）。
- [ ] N4.2 文档订正：`f_jit/doc/design-m1.md:1528` 与 `f_jit/doc/jit-bytecode-m1.md:2132` 的 A64 `NOT_B` 改为实际形态（`ldr x9,[x20]; eor x9,x9,#1; str x9,[x20]`），并补一句「机器字由 `A64Emitter.eorImm1` 构造」。验收：两处不再出现 `x11` 版本；与 `A64Lower` 一致。
- [ ] N4.3 索引回写：在 `f_jit/doc/spec/` 下补 `fix-jit-unary-not/` 的产物镜像（`proposal.md` / `design.md` / `tasks.md` / `specs/**`），与 `openspec/changes/fix-jit-unary-not/` 同源。验收：四件套齐全，与 OpenSpec 侧逐字一致。
- [ ] N4.4 提交：在 `fix/jit-unary-not` 上按「实现 + 测试」独立提交（先红用例与修复可同批提交，但提交信息须写明红→绿证据：`0xD2400009 → 0xD2400129`，`n=49: 巨大非零 → 0`）。验收：`git log` 可读；不夹带 N4.1 的审计改动。

## N5 收尾

- [ ] N5.1 `verify.md`：记录终态用例数 / 通过 / 失败、`n = 49` 修复前后原始输出、x86 证据状态、N4.1 审计结论（含「未发现 / 发现并另立」）。验收：每个判据都能指到可执行用例或原始输出。
- [ ] N5.2 归档：`openspec archive fix-jit-unary-not --yes`，delta 并入 `openspec/specs/`。验收：三个 capability 的 delta 全量落地（backend / differential-acceptance / compiler-frontend），`openspec list` 无同名活动变更。
- [ ] N5.3 合并：`git merge --no-ff` 回 master 并删除分支（按 AGENTS.md 的分支流程）。验收：master 上全量仍绿。

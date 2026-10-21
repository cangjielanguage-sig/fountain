# Tasks

> 纪律：每项先写**会失败**的用例（红），再改实现（绿），每批末跑全量。红态证据用「临时回退实现 → 跑新增用例 → 恢复」取得，不靠口头声明。

## B1 版本口径改为显式选项（X1）

- [x] B1.1 新增 `Version.LATEST` 与 `CompileOptions.verMajor`：先写失败用例——`CompileOptions(DummyDiagnosticsSink()).verMajor == Version.LATEST`，且 `Version.LATEST == Version.M3_MAJOR`；再把字段与常量落下。**（红态：`'verMajor' is not a member of class 'CompileOptions'`、`'LATEST' is not a member of class 'Version'`；绿：`optionsDefaultToLatestVersion` / `versionIsSettable`）**
- [x] B1.2 `CompilePipeline` 改用选项并纳入缓存键：先写失败用例——`opts.verMajor = M2` 后编译含 `Any` 的源码必抛 `SourceCompileException`；改回 `LATEST` 后编译通过并返回值；再改 `runSource` 与缓存键；验收：不支持的主版本在 `compile` 时报错，消息含请求值与支持集。**（`m2VersionRejectsAnySource` / `latestVersionAcceptsAnySource`；错误消息形如 `不受支持的 verMajor=9（支持：1/2/3）`，由 `supportedMajors()` 现算）**
- [x] B1.3 缓存不串版本：先写失败用例——先用 `LATEST` 编一段含 `Any` 的源码并调用，再用 M2 编同一源码必须仍失败（若键不含版本会命中缓存而不报错）；再确认键含 `v${verMajor}`。**（`versionIsPartOfCacheKey`；键格式 `src/<mode>/v<major>/fp<0|1>/<fnv>`）**

## B2 `strictFp` 归位编译期（X3）

- [x] B2.1 前端能发射 `FDIV_CHK`：先写失败用例——`strictFp = true` 的产物里 `Float64` 的 `/` 是 `0x44`，`false` 是 `0x43`（逐助记符断言，两处各一例）；再把 `strictFp` 从 `CompileOptions` 传到 `SourceCompiler` → `Lowerer`，在 `emitArith` 处选 opcode；验收：其余算术 opcode 不变。**（`strictEmitsFdivChk` / `looseKeepsFdiv` / `otherArithmeticUnaffected`；`FDIV_CHK` 与 `FDIV` 互斥出现）**
- [x] B2.2 语义端到端：先写失败用例——`{ x: Float64 => 1.0f64 / x }` 以 `x = 0.0` 调用，`strictFp=false` 得 `+Inf`（错误码 0）、`true` 以 1 失败；再确认解释器与 A64 结果一致（`FDIV_CHK` 两引擎既有语义）。**（`looseDivisionByZeroYieldsInf` / `strictDivisionByZeroFails` / `strictStillComputesNormalDivision`；A64 的 `floatBin(4)` 与 `Interp` 的 `0x44` 分支本就一致，本次只是让前端能发射）**
- [x] B2.3 删除无效字段：先写失败用例（编译失败即证据）——`CallContext().literalCopy` / `CallContext().strictFp` 不再存在；再删字段、删 `invoke` 里写 `ctx.flags` bit0 的两行，并改写 `CallContext_test`；验收：`CtxFlags.STRICT_FP` 保留且注释写明「运行期不读」。**（`CallContext_test` 只留 `args` / `deadline` 四例；`BaseVisibility_test` 与 `AnyBridgeCall_test.a3_5` 同步改写）**
- [x] B2.4 缓存不串 strict 配置：先写失败用例——同源码先 `false` 后 `true` 各编一次，严格产物必须报 ÷0（若键不含标记会命中非严格产物、返回 `+Inf`）；再确认键含 `fp${0|1}`。**（`strictFpIsPartOfCacheKey`）**

## B3 值型键统一为裸 cell（X2）

- [x] B3.1 取消 `f:` 前缀：先写失败用例——`CanonKey.f64(bits) == CanonKey.cell(bits)` 对 `1.5 / -0.0 / NaN 位模式` 三条都成立；再改 `f64` 实现；验收：`canonKeyOf(1.5f64) == CanonKey.cell(1.5f64.toBits())`。**（红态实测 `f:4609434218613702656` vs `i:4609434218613702656`；顺手新增 `CanonKey.bitsAsI64`——`Int64(bits)` 对 ≥2^63 的位模式抛 `OverflowException`）**
- [x] B3.2 承载形态无关：先写失败用例——同一个 `Float64` 以裸 cell 与 `any_box` 包装后作 `Map` 键，`mapKeyOf` 得到同一 `ConstMapKey`；再按 D3 修 `canonKeyOf`；验收：`1.5` 与 `2.5` 仍不同键。**（`x2_boxedAndRawFloatKeyAgree`；此用例逼出附带缺陷：`mapKeyOf` 对 `JitAnyBox` 未解包 ⇒ 所有装箱键塌成空串，已在 `IterTable` 修）**
- [x] B3.3 常量键端到端不回归：既有的 `p1_7_constMapFloatKeysHit` / `p1_7_constMapDecimalKeysHit` / `p1_7_canonKeyIsSingleSource` 全绿，且新增「装箱键命中常量条目」用例。**（三条既有用例全绿；`x2_*` 两条补不变式）**

## B4 `else if` 规格与门禁（X4，代码零改动）

- [x] B4.1 规格补条款：`else if` 需求增加值用法同构与「先判 `if` 再取块、禁止不可达分支」；`#### Scenario` 补齐语句/值用法三臂。**（delta 修改 `else if` 链的语法，保留原有两条 Scenario 名称，新增「值用法三臂」）**
- [x] B4.2 回归确认：`p1_4_elseIfParses` 已覆盖语句与值用法三臂，无需新增；`else` 后接非块仍报语法错误。**（既有用例逐臂断言 1/2/3 与 10/20/30；代码零改动）**

## B5 文档回写

- [x] B5.1 `design-m1.md` §8：`strictFp` 从 `CallContext` 行移到 `CompileOptions`，并写明「产物级、`FDIV` vs `FDIV_CHK`」。**（§2.3.4 表格删两行、补「只装调用级选项（X3 订正）」段；类型总表同步）**
- [x] B5.2 `jit-bytecode-m1.md` §2：`flags` bit0 标注「历史位，运行期不读」；结构体片段与 `CallContext 派生字段` 段同步。**（`48 8 flags bit0=strictFp（历史位，运行期不读）`；`tryInvoke` 的对外口径改为「不引入」）**
- [x] B5.3 `CallContext` / `CompileOptions` 类注释与新口径一致；`plan-m1.md` 里「S4.1/S6.4 联测」的旧承诺改为「已由本变更以编译选项收口」。**（三处注释/计划行同步；`CtxFlags.STRICT_FP` 标注历史位）**

## B6 总回归与归档

- [x] B6.1 全量回归：`cjpm test --parallel 1` 零失败零 error；用例数与基线（1076）对照留档。**（1090/1090 / 0 失败 / 0 error / 0 skipped）**
- [x] B6.2 `verify.md`：四项发现自己一行，含红→绿证据与落点用例名；另记录 X2 深挖出的两个附带缺陷。**（已出具）**
- [x] B6.3 归档：`openspec archive close-f-jit-out-of-checklist-findings --yes`（+2 added / ~4 modified），目录归档为 `archive/2026-10-21-close-f-jit-out-of-checklist-findings/`；同步 `f_jit/doc/spec/` 镜像

# Tasks

## 1. 红：固化复现与同型用例

- [ ] 1.1 复核 3 个崩溃用例（`CastOr_test`：`downcastFallsBackOnMismatch` / `bareCastFailsWithBadCast` /
      `unknownClassNameUsesRuntimeCheck`）在 x86_64 上仍以 SIGSEGV 失败，并在用例注释中登记
      「RED 证据：修复前 1091 例中 3 ERROR」；验证：`cjpm test --filter CastOr_test` 复现崩溃（exit 非 0）
- [ ] 1.2 新增同型用例（表达式 `if` 的 else 分支内含 `argc ≥ 1` helper；`while` 回边后调用 helper），
      先确认**修复前失败**；验证：新增用例在 x86_64 上失败、且失败原因是本缺陷（崩溃或错值）
- [ ] 1.3 在 `X86Lower_test` 增加**字节级**断言：汇合点之后的 helper 调用前有
      `sub rsp,8`、返回后有 `add rsp,8`，且与汇合深度奇偶一致；验证：该断言修复前失败

## 2. 深度分析器（`X86Depth`）

- [ ] 2.1 实现 `stackEffect(op, operands): ?StackEffect` 并按语义分组登记全部已分配 opcode；
      新增**表完整性用例**（157 个已分配 opcode 全部非 None 或在终止/零效应白名单中）；
      验证：完整性用例通过、故意删一条登记时该用例失败
- [ ] 2.2 实现 `analyzeDepth(code, codeOff, codeLen): ?HashMap<Int64, Int64>`（工作列表数据流，
      `JMP/JZ/JNZ/LOOP_BACK` 后继正确、终止类不传播、汇合不一致 ⇒ None、未识别指令 ⇒ None）；
      验证：单测覆盖「直链」「条件汇合」「回边」「汇合不一致」「未识别指令」五形态

## 3. 接入 `X86Lower`

- [ ] 3.1 `lower()` 先调 `analyzeDepth`，`None` ⇒ `ok = false` 并直接返回（整单元退回解释器）；
      循环体内以 `depthAt[off]` 设定 `this.depth`，移除线性累加依赖；
      验证：`X86Lower_test` 的既有字节断言全绿 + `fallback` 用例（异常单元退回解释器）通过
- [ ] 3.2 让 §1 的 3 个崩溃用例与 1.2 的同型用例转绿；验证：`cjpm test --filter CastOr_test`
      **不再崩溃**且断言正确（`fallback` 值、`7` 错误码、运行期判定结果）
- [ ] 3.3 让 1.3 的字节级对齐断言转绿；验证：`cjpm test --filter X86Lower_test` 通过

## 4. 回归与差分

- [ ] 4.1 跑**全量** `cjpm test`：1091/1091、0 ERROR（修前基线 1084/1091、3 ERROR）；
      验证：`Summary: TOTAL: 1091 / PASSED: 1091 / FAILED: 0 / ERROR: 0`
- [ ] 4.2 跑三引擎差分（`fountain::f_jit.test.diff`）逐位一致（结果 / 错误码 / site / 报告文本）；
      验证：差分用例全绿
- [ ] 4.3 性能抽查：`cjpm test --filter PerfCompare_test --no-capture-output` 记录 JIT/native/interp
      三档数字，确认预扫开销在噪声内；验证：数字留档于本变更或 `doc/perf-m1.md`

## 5. 文档同步

- [ ] 5.1 `jit-bytecode-m1.md` §12.3/§12.4 补「深度由控制流推导、对齐补丁由该深度决定」口径；
      `design-m1` 附 C 若含对齐说明同步；验证：规格文本可被 grep 到该条且与实现一致
- [ ] 5.2 `f_jit/doc/spec/f-jit-m1/verify.md` 追加本次回归证据（修前 3 ERROR、修后 1091/1091、
      真机 x86_64 环境与日期）；验证：verify.md 含该条且命令可复跑

## Workflow follow-up

- 用户评审本 `design.md` / `tasks.md` 后再进入 apply。
- 全部任务完成后执行 `opsx:verify`（CRITICAL 清零），再 `opsx:archive`。
- 提交与推送按仓库既有规范（一次提交只含本修复 + 用例 + 文档）。

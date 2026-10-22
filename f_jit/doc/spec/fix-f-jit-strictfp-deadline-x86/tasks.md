# Tasks

## 1. 红（既有失败即 RED）

- [x] 1.1 复核 4 例在 x86_64 上 FAILED（`defaultIsStrict` / `strictDivisionByZeroFails` /
      `strictFpIsPartOfCacheKey` / `p0_6_deadlineInterruptsLoop`）；验证：`cjpm test --filter StrictFp_test`
      与 `--filter AnyBridgeCall_test` 显示对应 FAILED

## 2. 修复 `FDIV_CHK`

- [x] 2.1 `floatDivChk` 首个条件跳转 `jnp(0x8B) → jp(0x8A)`；验证：3 个 strictFp 用例转绿
- [x] 2.2 `X86Lower_test` 增字节断言「`FDIV_CHK` 编译产物首个条件跳转为 `0F 8A`」；验证：该断言通过，
      回退到 `0F 8B` 时失败

## 3. 修复回边安全点

- [x] 3.1 `case 0x74u8` 增 STACK_GUARD（`(rbp-frame)-rsp < frame ⇒ errCode=-1 + jmp epilogue`）
      与 H22 `interrupt_poll`（占位出栈）；验证：`p0_6_deadlineInterruptsLoop` 转绿
- [x] 3.2 栈余量分支的防御性验证：构造/复用 deopt 用例确认 `-1` 仍透明重放（结果与纯解释一致）；
      验证：既有 deopt 用例全绿

## 4. 回归

- [x] 4.1 全量 `cjpm test`：**1098/1098**（0 ERROR / 0 FAILED）；验证：Summary 数字
- [x] 4.2 三引擎差分 11 例全绿；验证：`test.diff` 全绿
- [x] 4.3 `PerfCompare` 留档（回边新增检查的代价）；验证：数字写入交付说明

## 5. 文档

- [x] 5.1 `jit-bytecode-m1.md` §12.4 补两条口径（`FDIV_CHK` 谓词、`LOOP_BACK` = STACK_GUARD + H22）；
      验证：规格文本可 grep 且与实现一致
- [x] 5.2 `verify.md` 追加 2026-10-22 第二轮记录（4 例 RCA 与修复、全量数字）

## Workflow follow-up

- 用户已确认「重走全流程，修复 4 个 FAILED」（2026-10-22），本变更按 propose → apply → verify → archive 推进。
- 完成后 `opsx:verify`（已安装 `openspec-verify-change` 技能）+ `opsx:archive`。

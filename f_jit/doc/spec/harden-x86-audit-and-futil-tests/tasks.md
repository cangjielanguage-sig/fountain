# Tasks

## 1. x86 审计绝对地址例外

- [x] 1.1 `BackendX86_64` 增 `noteAbsMem()`（哨兵 `-1`），`auditAllows` 接受 `-1`
      验证：`cjpm test --filter EmitAudit_test` 的 `absoluteAddressIsExempt` 通过
- [x] 1.2 `X86Lower` 在 `PUSH_KH`（case 0x16）与 `callFunc` 的绝对地址解引用处登记
      验证：含常量单元的 `isJitBacked()` 为真（见 2.2）

## 2. 用例

- [x] 2.1 `EmitAudit_test` 增 `absoluteAddressIsExempt`（允许集含 `-1`、拒绝 `0`、采集含 `-1`）
      验证：该用例通过
- [x] 2.2 新增 `src/JitBacked_test.cj`：`plainUnitStaysJitBacked`（纯算术）与
      `constMirrorUnitStaysJitBacked`（字符串字面量 ⇒ `PUSH_KH`）
      验证：两例通过且 `isJitBacked()` 为真

## 3. f_util 用例执行

- [x] 3.1 在 WSL x86_64 执行 `cd f_util && cjpm test`，记录用例数/通过数/失败数
      验证：命令可复跑、结果写入 `verify.md`

## 4. 回归与文档

- [x] 4.1 f_jit 全量：**1109 + 3 例**，0 FAILED / 0 ERROR
      验证：Summary 数字
- [x] 4.2 `verify.md` 第五轮记录（审计对称化、f_util 执行结果、`CALL_FUNC` 源级用例的缺口）
      验证：文档可 grep

## Workflow follow-up

- 用户确认（2026-10-22）："要"——按建议补 x86 对称化与用例，并把 f_util 测试纳入执行。
- 完成后 `opsx:verify` + `opsx:archive`。

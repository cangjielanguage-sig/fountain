# Tasks

> 归档反写：以下步骤依据 `plan-m2.md Q 系列` 与代码现状整理，全部已完成（`[x]`）。

- [x] 签名编码 `SignatureDescriptor` 与验签
- [x] `CALL_HOST` 发射与 H63
- [x] 特化 trampoline 与失效条件
- [x] 捕获分析 `CaptureDescriptor`
- [x] 提升组引用计数与 `close`

## 验收

- 全量测试通过（见 `verify.md` / `scenario-map.tsv`）；
- 三引擎（Interp / AArch64 / 可用时 x86_64）结果、错误码、site 逐位一致。

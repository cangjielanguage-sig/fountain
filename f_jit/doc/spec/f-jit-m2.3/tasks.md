# Tasks

> 归档反写：以下步骤依据 `plan-m2.md Q 系列` 与代码现状整理，全部已完成（`[x]`）。

- [x] castRelation 三态（静态/运行期/不相容）
- [x] `$as$<C>` 合成与 `$as$` 槽解析
- [x] H77 与失败面
- [x] `SignaturePlan` / adapter 生成
- [x] `as T ?? V` 的兜底求值时机

## 验收

- 全量测试通过（见 `verify.md` / `scenario-map.tsv`）；
- 三引擎（Interp / AArch64 / 可用时 x86_64）结果、错误码、site 逐位一致。

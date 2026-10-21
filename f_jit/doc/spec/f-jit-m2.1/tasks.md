# Tasks

> 归档反写：以下步骤依据 `plan-m2.md Q 系列` 与代码现状整理，全部已完成（`[x]`）。

- [x] 反射 TypeInfo → LocalType 映射（值型/句柄型/其余 14）
- [x] 字段表与方法表快照
- [x] `@JitBind` overrides 路径
- [x] 构造器条目与 `PublicCtor` 物化
- [x] 成员访问降低与 `requireMethod`/`requireField` 诊断

## 验收

- 全量测试通过（见 `verify.md` / `scenario-map.tsv`）；
- 三引擎（Interp / AArch64 / 可用时 x86_64）结果、错误码、site 逐位一致。

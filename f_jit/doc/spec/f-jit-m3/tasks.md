# Tasks

> 归档反写：以下步骤依据 `plan-m3.md R0–R6` 与代码现状整理，全部已完成（`[x]`）。

- [x] LocalType 15 与 16–19 的合法集扩展（verMajor 3）
- [x] H78–H80 与窗口记账
- [x] JSON 字面量与常量实例化
- [x] JSON 访问糖（点号成员优先 → 键兜底、下标收窄）
- [x] H81–H83 与 frozen
- [x] 三引擎对拍与矩阵

## 验收

- 全量测试通过（见 `verify.md` / `scenario-map.tsv`）；
- 三引擎（Interp / AArch64 / 可用时 x86_64）结果、错误码、site 逐位一致。

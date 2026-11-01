# Spec Delta — f-excel-ods

## ADDED Requirements

### Requirement: ods 可行性评估

M3 SHALL 产出 `ods-assessment.md`，覆盖：`content.xml` / `styles.xml` 与 OOXML 的映射、
可复用模块、差异（公式/样式/日期/图片/合并）、风险、工作量与明确结论（做 / 不做 / 何时做）。

#### Scenario: 结论可执行

- **WHEN** 阅读评估报告
- **THEN** 能回答"是否做、复用哪些模块、主要风险与预估工作量"

### Requirement: 不实现 ods

M3 SHALL NOT 增加 ods 读写 API；`ExcelDocument` 对 `.ods` 输入 SHALL 继续抛"不是有效的 xlsx 文件"。

#### Scenario: ods 输入

- **WHEN** 用 `.ods` 文件构造 `ExcelDocument`
- **THEN** 抛 `ExcelException`，消息明确不是 xlsx

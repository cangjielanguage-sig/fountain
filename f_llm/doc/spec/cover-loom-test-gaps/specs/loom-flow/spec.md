# Spec Delta

## ADDED Requirements

### Requirement: 提炼的边界语义

`LoomMemoryExtractor.extract` 在输入为空时 MUST 直接返回 0 且不写库；写知识失败时 MUST 只丢那一条，记忆与经验照常写入。

#### Scenario: 没有对话轮

- **WHEN** `turns` 为空
- **THEN** 返回 0，记忆表无新增

#### Scenario: 写知识失败

- **WHEN** `writeKnowledge=true` 但 `knowledge.upsert` 抛错
- **THEN** 返回 2（note + experience），不抛异常

### Requirement: 工具删除的精确性

`memoryCall` 的 `remove` MUST 按调用方给的 id 删除，MUST NOT 删除其它记录；重复删除同一 id MUST 返回 `false`。

#### Scenario: 删一次再删一次

- **WHEN** 先用 add 返回的 id 删除，再用同一 id 删除一次
- **THEN** 第一次成功（`true`），第二次 `false`

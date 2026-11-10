# Spec Delta

## ADDED Requirements

### Requirement: 经验检索的 kind 强制

`loomStore("experience", "list", payload)` MUST 只返回经验类记录，无论调用方是否显式给出 `kind`；`add` / `search` / `list` 三个 op 对 `experience` 的 kind 语义 MUST 一致。

#### Scenario: 不传 kind 列经验

- **WHEN** 同一用户下既有 `note` 又有 `experience` 记录，调用 `loomStore("experience","list",{userId,namespace})`
- **THEN** 返回结果只含 `kind=experience` 的记录

#### Scenario: 显式传其它 kind

- **WHEN** 调用 `loomStore("experience","list",{kind:"note"})`
- **THEN** 显式值优先，返回 note（与 `search` 的既有行为一致）

### Requirement: 人格的「无正文」判定

解析人格时，`default` 关键字、以及提示词库中 `content` 为空的条目 MUST 被视为「本级无正文」并继续下沉；内置角色存在但正文为空时 MUST NOT 退化为把关键字本身注入 system。

#### Scenario: default 不注入

- **WHEN** `persona = "default"` 且该用户没有 character 记录
- **THEN** system 中不出现任何人格文本，也不出现单词 `default`

#### Scenario: 空提示词下沉到内置

- **WHEN** 提示词库有同名条目但 `content` 为空，且该 key 是内置角色
- **THEN** 使用内置角色正文

#### Scenario: 空提示词 + 未知 key 回落字面

- **WHEN** 提示词库条目 `content` 为空，且 key 不是内置角色
- **THEN** 按字面文本注入（保持原有第三级语义）

#### Scenario: custom 不受影响

- **WHEN** `persona = "custom"`
- **THEN** 人格正文只来自 `character.prompts`，不查提示词库也不查内置

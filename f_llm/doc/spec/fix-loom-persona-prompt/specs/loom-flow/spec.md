# Spec Delta

## ADDED Requirements

### Requirement: 人格归属与记忆策略解耦

character 记录的 user 归属 MUST 来自独立的人格作用域（`LoomCharacterScope`），未安装时才回落 `LoomMemoryPolicy.userId`；`LoomWiring.wire` MUST 提供 `characterUserId` 参数并安装该作用域。

#### Scenario: 记忆策略 userId 为 0 时人格仍生效

- **WHEN** `LoomMemoryPolicy.userId=0`，但 `LoomCharacterScope` 安装为 9，且用户 9 有 character 记录（`rigorous`）
- **THEN** 流程 system 注入 `rigorous` 的内置正文

### Requirement: 技能注入的回落

显式传入的技能标题 MUST 以「解析到的正文是否为空」作为是否回落的判据；当显式标题全部未命中且开启 `autoSkills` 时 MUST 回落到 `SkillCatalog` 检索。

#### Scenario: 标题写错

- **WHEN** `run(skills: ['不存在的技能'])`，任务描述能命中某个已注册技能
- **THEN** 该技能正文仍被注入

### Requirement: 提示词版本语义一致

`prompt.get` 在 `version<=0` 时 MUST 返回最新版本；`prompt.remove` 在 `version<=0` 时 MUST 抛错说明必须指定版本，MUST NOT 静默返回失败。

#### Scenario: get 不传版本

- **WHEN** 提示词有 v1、v2，调用 `loomStore("prompt","get",{name,version:0})`
- **THEN** 返回 v2 的内容

#### Scenario: remove 不传版本

- **WHEN** 调用 `loomStore("prompt","remove",{name,version:0})`
- **THEN** 抛错，错误信息包含 `version`

### Requirement: 提炼只记步骤上下文

提炼记忆时记录的对话轮 MUST 使用步骤自身的 system，MUST NOT 包含执行期拼接的人格与技能前缀。

#### Scenario: 有人格时不污染记忆

- **WHEN** 流程指定 `persona="严格"` 并开启提炼
- **THEN** 落库的记忆正文中不出现 `严格`

# Proposal

## Why

R3 的四处问题都在「人格 / 技能 / 提示词」这条链上，共同点是**配置看起来生效、实际没生效或串了味**：

- character 人格与 `character.prompts` 依赖 `LoomMemoryPolicy.userId`（默认 0），默认配置下 `characterOf(0)` 直接返回 `None` —— 配了人格不生效、也无任何提示；
- 显式传的 `skills` 标题全部打错/改名时，`skillBlock` 为空却**抑制了自动检索**，流程一个技能都拿不到；
- `prompt.get` / `prompt.remove` 没有 `version<=0` 语义：`get(name,0)` 永远返回空串、`remove(name,0)` 永远 false，与 `put` 的自增语义不对称；
- 提炼记忆时 `LoomContextLog` 记录的是**拼好人格与技能块的 fullSystem**，于是人格正文与技能清单被当成「事实」写进记忆/知识，污染检索并形成自反馈。

## What Changes

- 新增 `LoomCharacterScope`（进程级、可 install/reset）：`LoomRunner` 优先用它取 character 的 userId，未安装才回落 `LoomMemoryPolicy.userId`；`LoomWiring.wire` 增加 `characterUserId!` 并安装。
- 技能注入：显式标题**全部没命中**时回落 `SkillCatalog` 自动检索（判断依据从「入参是否为空」改为「解析结果是否为空」）。
- `prompt.get`：`version<=0` 走 `latest`；`prompt.remove`：`version<=0` 抛错说明必须给版本（不静默 false）。
- 提炼记录：`LlmTurn` 记**步骤自身的 system**，不带人格/技能前缀。

## Capabilities

### Modified Capabilities
- `loom-flow`：人格归属与记忆策略解耦；技能注入有回落；提示词版本语义一致；提炼只记步骤上下文。

## Impact

- 代码：`src/loom/LoomCharacterScope.cj`（新增）、`LoomRunner.cj`、`LoomWiring.cj`、`LoomStoreGateway.cj`、`LoomHostApi.cj`。
- 行为：默认配置（policy.userId=0）下若未安装 scope，人格仍不生效 —— 但现在有显式入口，不再是「无处可配」。
- 测试：新增 5 条。

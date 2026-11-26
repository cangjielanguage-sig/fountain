# Proposal

## Why

代码审查（R2 / R3）发现两处「读起来像支持、实际悄悄错」的缺陷：

- `loomStore("experience", "list", …)` **不强制 kind**：`add` 与 `search` 都用了 `kindOf(args, defaultKind)`，只有 `list` 直接读 `args.kind`，不传 kind 时返回**所有** kind 的记忆，调用方以为拿到的是经验；
- `characterKey = "default"` 被当成**字面人格**注入 system（英文单词 `default` 进了提示词）；同理，提示词条目 `content` 为空时会提前 `return ''`，把内置人格也一起屏蔽。

## What Changes

- `LoomStoreGateway` 的 `list` 分支改用 `kindOf(args, defaultKind)`，与 `add`/`search` 对齐。
- `LoomRunner` 的人格解析：
  - `default`（大小写/空白不敏感）与 `custom` 一样视为「无正文」；
  - 提示词库命中但 `content` 为空 → 视为「本级无内容」，继续下沉，不再提前返回空；
  - 内置角色 `bodyOf` 为空但 `isKnown(key)` 为真 → 视为「该角色就是不注入」，不再退化成字面文本。
- 补 5 条用例：经验 list 只返回经验、`default` 不注入、空 content 下沉到内置、空 content + 未知 key 回落字面、`custom` 行为不变。

## Capabilities

### Modified Capabilities
- `loom-flow`：`experience.list` 的 kind 语义与人格「无正文」的判定显式化。

## Impact

- 代码：`src/loom/LoomStoreGateway.cj`、`src/loom/LoomRunner.cj`（各一处判断）。
- 行为：`experience.list` 不带 kind 时只返回经验（此前返回全部）——这是修正，不是新增开关。

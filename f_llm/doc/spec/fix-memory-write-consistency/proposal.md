# Proposal

## Why

代码审查（R1）指出记忆写入链路不一致：

- `Memory.remember(session, summary)` 直接 `MemoryStoreAdapter().add(...)`，**绕过** `LoomHostApi.callStore` 网关，形成第二套 JSON 协议；且写死 `namespace='global'`、`kind='session'`，而 loom 默认命名空间是 `loom` —— loom 内 `loomStore("memory","search",{namespace:"loom"})` **永远召回不到**这些摘要。
- `MemoryKinds` 只登记 7 个预定义 kind，`experience` / `experience_failed` 靠字面量散落在 4 个文件里；`validate` 返回 false、`weightOf` 落到默认分支。

## What Changes

- `Memory.remember` 增加 `namespace!` / `kind!` 参数（默认 `loom` / `session`），改为**优先走网关** `LoomHostApi.callStore("memory","add", …)`；未装配时回落到适配器（保持既有可用性）。
- `MemoryKinds` 增加 `EXPERIENCE` / `EXPERIENCE_FAILED` 常量并纳入 `predefined()`；`weightOf` 给两者显式 `0.8`（与当前默认一致，不改变排序）。
- `LoomMemoryPolicy` / `LoomStoreGateway` / `SkillEvolutionJob` 的 kind 字面量改用常量。
- 补 4 条用例：remember 走网关且带 namespace/kind、未装配回落、`predefined()` 含两个新 kind、权重不变。

## Capabilities

### Modified Capabilities
- `loom-flow`：记忆写入统一走网关；经验 kind 纳入预定义集合。

## Impact

- 代码：`src/memory/Memory.cj`、`src/store/MemoryKinds.cj`、`src/loom/{LoomMemoryPolicy,LoomStoreGateway,SkillEvolutionJob}.cj`。
- 行为：`Memory.remember` 默认写入的 namespace 从 `global` 变为 `loom`，与 loom 检索默认值对齐（此前写进去也检索不到）。

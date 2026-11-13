# Proposal

## Why

代码审查（R6）唯一的严重性能问题：`LoomWiring.wire` 安装的 `loomStore` 闭包是

```cangjie
LoomHostApi.installStore({ kind, op, payload => LoomStoreGateway().call(kind, op, payload) })
```

**每次调用都新建网关**。`LoomStoreGateway()` 的无参构造会 `Stores.content()` + `Stores.meta()` + `EvolutionStores.current()`，
按 R6 的实测路径展开是 **3 次配置读 + 2~3 次打开本地库/新建传输**。一个 10 步流程里 5 个 store 步骤 = 15 次配置读 + 约 12 次开库。

同一问题还有两处：`memoryCall` / `knowledgeIngest` 两个工具在未注入网关时也各自 `LoomStoreGateway()`，与 `loomStore` 读的不是同一个实例。

## What Changes

- `LoomWiring.wire` 在装配期建**一个**网关，`installStore` 闭包复用它；新增可选参数 `gateway!` 便于测试/自定义。
- `memoryCall` / `knowledgeIngest` 在未注入网关时改走 `LoomHostApi.callStore`，与流程内 `loomStore` 共用同一实例（未装配时回落到自建，保持原有可用性）。
- `SkillEvolutionJob.load` 在装配路径上也复用同一网关。
- 给 `LoomStoreGateway` 加一个包内可见的构造计数，用于验证「装配期只建一次」。

## Capabilities

### Modified Capabilities
- `loom-flow`：`loomStore` 与两个存储工具 MUST 共用装配期创建的单个网关。

## Impact

- 代码：`src/loom/LoomWiring.cj`、`src/loom/StoreFunctions.cj`、`src/loom/LoomStoreGateway.cj`（计数）。
- 性能：store 步骤的固定开销从「每步 3 次配置读 + 开库」降到「每次装配一次」。
- 行为：`memoryCall`/`knowledgeIngest` 在已装配环境里与 `loomStore` 完全同源；未装配环境仍可自建（不破坏既有单测）。

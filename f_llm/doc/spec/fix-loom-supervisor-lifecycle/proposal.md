# Proposal

## Why

R7 剩下三条都属 Supervisor / 装配的生命周期问题：

- `dispatch` 二次校验发现流程已不是 `compiled` 时**只返回不摘除**，这条陈旧路由会一直留在候选里被模型选中、每次白烧一次选路调用；`routable()` 与 `service.status()` 还在 try 之外，存储不可用会直接抛给调用方；
- `LoomBootstrap.startup` 的 `restoreFailed` 只有直接调用才能看到，`LoomWiring.wire` 丢弃返回值——生产上「库比应用晚就绪」时应用照常启动、路由表静默为空、**没有任何日志**；
- `wire` 无条件 `installHost(DefaultLoomHost(chat))`，调用方预先装好的宿主被覆盖，Supervisor 与执行路径可能绑到两个不同宿主。

## What Changes

- `dispatch`：状态漂移时**先 `unregister` 再返回** `noUsableFlow`；`routable()`、`service.status()` 包进 try，异常按「无可用流程」处理。
- `wire`：保留 `LoomBootstrap.startup` 的返回值，暴露 `LoomWiring.lastReload()`；`restoreFailed` 为真时打 warn 日志；`ReloadResult.toString()` 带上该字段。
- `wire`：新增 `host!` 参数；已有宿主时**不覆盖**，优先级 `传入 host` > `已安装 host` > `DefaultLoomHost(chat)`。

## Capabilities

### Modified Capabilities
- `loom-supervisor`：陈旧路由必须被摘除；装配失败必须可观测；装配不得覆盖宿主。

## Impact

- 代码：`src/loom/Supervisor.cj`、`src/loom/LoomWiring.cj`、`src/loom/LoomBootstrap.cj`（`toString`）。
- 行为：状态漂移的流程从「反复被选中」变为「摘除后不再出现」；`wire` 不再抢宿主。
- 测试：新增 4 条（漂移摘除、选路存储异常、`lastReload` 标记、宿主不被覆盖）。

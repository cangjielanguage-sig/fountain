# Proposal

## Why

R4 的五条问题都有同一个根：**归属信息没写进数据，也没写进装配**。

- `writeKnowledge` 的 docId 是 `loom:<flow>:<进程内序号>`：重启后序号归零，撞上历史文档即覆盖；换租户更会串；
- `LoomMemoryPolicy.current` 是无锁静态变量，与同目录其它组件（都用 `Mutex`）不一致；
- `wire` 的 `evolutionUserId/Namespace` 与 `memoryPolicy` 完全解耦：典型误配是「经验写在 7/work，演进按 0/loom 查」，永远读不到，且无告警；
- 知识侧素材不按租户过滤，任何人的 `writeKnowledge` 都会进所有人的演进池；
- 提炼失败三层 `catch` 静默，`written` 计数被丢弃，出问题时没有任何痕迹。

## What Changes

- `docId` 改为 `loom:<userId>:<namespace>:<flow>:<时间戳>-<序号>`，归属随 id 走。
- `LoomMemoryPolicy` 的 install/reset/effective 全部加锁。
- `LoomWiring.evolutionOwner(policy, userId, namespace)`：显式值优先，否则跟随记忆策略；`evolutionNamespace` 默认值改为空串以便判定「没给」。
- `SkillEvolutionJob.ownedBy(docId, userId, namespace)`：知识素材按租户前缀过滤，旧格式（无法判定归属）一律不取。
- 提炼：`written==0` 与异常都打 warn 日志。

## Capabilities

### Modified Capabilities
- `loom-flow`：知识文档带归属、演进读写同源、提炼失败可观测。

## Impact

- 代码：`LoomMemoryPolicy.cj`、`LoomWiring.cj`、`LoomRunner.cj`、`SkillEvolutionJob.cj`。
- 数据：新 `docId` 带租户前缀；旧格式知识不再进演进池（宁可少取不串味）。
- 测试：新增 3 条；更新 2 条既有断言（docId 格式、演进素材前缀）。
- 未覆盖：演进素材 `limit=500` 上限与水位线无条件推进（需改 `SkillEvolutionJob.run` 的水位线语义，单独变更处理）。

# fmq / f_mq 遗留项（归档，暂不实现）

> 归档日期：2026-10-18。以下问题来自代码与测试复核，经评审确认**本轮不实现**；
> 后续确有需要时再按 OpenSpec 六步另开变更承接。

## P0（可靠性相关）

1. **备份状态未真正复制**
   `MQBackupPayload.states` 的 `deliverCount` 固定 0、`acked` 固定 false
   （`fmq/src/cluster/BackupReplicator.cj:110`）；接收端只 `append` 记录，忽略 `states`
   （`fmq/src/server/MQCommandExecutor.cj:162-168`）。备份无法恢复消费进度。
2. **备份发送失败即丢**
   `flush()` 先清空 `pending` 再发送；`targets` 为空或 `send` 失败只记 WARN，整批丢弃，
   没有重试队列（`fmq/src/cluster/BackupReplicator.cj:84-125`）。
3. **运行期元数据广播失败不补齐**
   广播失败只记 WARN「peer will catch up on startup」，对端在重启/死转活前一直使用旧元数据
   （`fmq/src/cluster/MetaSyncer.cj:169-179`）。
4. **连接缓存关闭后不重建**
   `MQNodePool.clientOf` / `NodeRegistry.clientOf` 遇到 `isClosed()` 直接抛错，不重建客户端
   （`f_mq/src/client/MQNodePool.cj:71-77`、`fmq/src/cluster/NodeRegistry.cj:100-105`）；
   目前依赖 `f_net` 内部重连，缺少显式恢复与测试。

## P1（能力相关）

5. **消费消息不暴露 messageId / 发布时间**
   `MQMessage` 只有 topic/tags/body/位置（`f_mq/src/base/model/MQMessage.cj:29-45`），
   `publish` 也不返回 id；at-least-once 下业务侧难以做幂等去重与链路追踪。
6. **`deliveries` 映射无上限**
   非 autoAck 订阅每消费一条写入映射，只有 `ack` 才删除（`f_mq/src/client/MQSubscription.cj:37`、
   `f_mq/src/client/MQClient.cj:212`）；长期不 ack 会持续增长。
7. **订阅 owner 是快照**
   `subscribe` 时固定 owners（`f_mq/src/client/MQClient.cj:151-155`）；节点恢复或新增不会自动纳入，
   必须重新订阅。
8. **无死信读取/重放接口**
   `DeadLetterQueue` 全部方法为 `protected`（`fmq/src/queue/DeadLetterQueue.cj`），
   客户端与 manager 都无法查询或重放死信。
9. **客户端 API 较窄**
   无批量/异步发布、无按位点或时间 seek、无消费限流；空队列轮询间隔 200ms
   （`f_mq/src/client/MQClient.cj:41`），无服务端 long-poll。
10. **静态成员，无再平衡**
    节点表来自 `mqClient_hosts`，主题注册时一次性分配；扩缩容不迁移队列、不重新分配。

## P2（暂记录，不展开）

- 增量元数据同步（当前始终全量快照）
- 服务端关闭 drain、删除主题与在途消费并发
- 大消息 E2E 边界、多实例 MetaSyncer 集成测试
- 消息级 TTL、压缩、批量发布、动态成员

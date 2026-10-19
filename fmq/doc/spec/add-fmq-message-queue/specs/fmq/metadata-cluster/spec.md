# fmq 元数据与集群（delta）

## ADDED Requirements

### Requirement: 队列轮转分配

注册主题时 SHALL 按「队列 i → 节点 `(start + i) % nodeCount`」分配，并把下一主题的起始下标推进为
`(start + queueNum) % nodeCount`。分配结果 SHALL 自包含（含 `queueNum`、`startNodeIndex` 与
每个队列的 owner），不依赖各节点对节点表的一致理解。

#### Scenario: 规格示例逐字复现

- **WHEN** 3 节点、`/topic1` 4 队列、start = 0
- **THEN** `owners = [0,1,2,0]`、`nextStart = 1`；随后 `/topic2` 2 队列得到 `owners = [1,2]`

#### Scenario: 单节点

- **WHEN** 节点数为 1
- **THEN** 全部队列 owner 为 0，起始下标保持 0

#### Scenario: 单队列环绕

- **WHEN** start = 2、节点数 3、1 队列
- **THEN** owner 为 2，下一 start 为 0

#### Scenario: 非法队列数

- **WHEN** `queueNum <= 0`
- **THEN** 抛异常，注册请求回 `ERROR`

### Requirement: 元数据目录与原子写

元数据 SHALL 存放在 `<fmq 可执行目录>/metas/`，布局为：

```
metas/assign.meta
metas/topics/<topicEsc>.meta
metas/groups/<topicEsc>/<groupEsc>.meta
metas/offsets/<topicEsc>/<queueIndex>/<groupEsc>.cursor
```

文件名 SHALL 使用可逆、无碰撞的百分号编码（仅保留 `[A-Za-z0-9._-]`，空串编码为 `%00`）。
写入 SHALL 先写 `<file>.tmp` 再 rename 覆盖，避免半写文件。

#### Scenario: 路径布局

- **WHEN** 为 `/order` 的默认组生成路径
- **THEN** 组文件为 `groups/%2Forder/%00.meta`，主题文件为 `topics/%2Forder.meta`

#### Scenario: 编码无碰撞

- **WHEN** 分别编码 `/a_b` 与 `/a/b`
- **THEN** 两者结果不同，且都能解码回原名

#### Scenario: 原子写

- **WHEN** 写入前目录里已有同名的 `.tmp` 残留
- **THEN** 正式元数据文件仍完整可读，不被半截内容污染

### Requirement: 元数据持久化与内存索引

`MetaStore` SHALL 在启动时加载全部主题、订阅组与轮转指针；对外提供按主题查询分配、
按主题列出组、判断组是否存在、读取下一个起始下标与生成全量快照。
重复注册 SHALL 返回「已存在」且不改变已有内容。

#### Scenario: 重建后一致

- **WHEN** 注册主题与组后关闭并重开 `MetaStore`
- **THEN** `topicOf` / `groupsOf` / `nextStartNode` 与关闭前一致

#### Scenario: 重复注册

- **WHEN** 对同一主题再次 apply
- **THEN** 返回 duplicated，已有 owners 与 queueNum 不变

#### Scenario: 默认组存在性

- **WHEN** 已注册默认组 `""`
- **THEN** `groupExists(topic, "")` 为真

#### Scenario: 删除主题级联

- **WHEN** 删除某主题
- **THEN** 该主题下的所有订阅组元数据一并消失

#### Scenario: 快照内容完整

- **WHEN** 调用 `snapshot()`
- **THEN** 返回全部主题分配、全部订阅组与当前轮转指针

#### Scenario: 损坏文件跳过

- **WHEN** metas 目录里存在无法解码的文件
- **THEN** `load()` 不抛异常，跳过该条并记 ERROR，其余元数据可用

### Requirement: 元数据全量复制

每个节点 SHALL 保存全部主题与订阅组元数据。注册/注销 SHALL 先本地落盘，再广播给其它所有节点，
最后回响应；广播使用 `MQInternalMessage{kind: "metaSync"}` 承载，不新增协议命令。

#### Scenario: 注册后各节点一致

- **WHEN** 节点 X 收到主题注册
- **THEN** X 本地落盘后，每个可达 peer 都收到同一份 `MQTopicAssignment`，内容与 X 完全一致

#### Scenario: 重复应用幂等且不转发

- **WHEN** 同一份变更被应用两次
- **THEN** 第二次返回 duplicated，且不会再次广播（防止广播环）

#### Scenario: 冲突保留先到者

- **WHEN** 两个节点对同一主题给出不同的 owners
- **THEN** 保留先到者，返回 conflict 并记 WARN，不覆盖已有分配

#### Scenario: 注销复制

- **WHEN** 节点收到主题/组注销
- **THEN** 本地删除对应元数据与相关订阅/游标，并向 peer 广播删除

### Requirement: 启动期与恢复期同步

节点启动时 SHALL 向第一个可达 peer 请求全量快照并合并（本地缺失的补齐）；
当全部 peer 不可达时 SHALL 保留本地元数据继续启动并记 WARN，不得因此拒绝启动。
由死转活时 SHALL 触发一次重同步。

#### Scenario: 补齐缺失

- **WHEN** 本地为空，peer 快照含 2 个主题与 1 个组
- **THEN** 全部补齐，`nextStartNode` 取较大值

#### Scenario: 全部不可达

- **WHEN** 所有 peer 都连不上
- **THEN** 服务仍启动，使用本地元数据，日志有 WARN

### Requirement: 节点表与身份

服务端 SHALL 从 `mqClient_hosts` 读取节点表（顺序即下标），并 SHALL 用 `mqServer_port`
与表中某项的端口匹配来确定本机下标。端口在表中不存在或出现重复端口时 SHALL 拒绝启动。
节点间 SHALL 复用 `f_net` 客户端内建心跳完成探活与重连。

#### Scenario: 按端口定位自身

- **WHEN** 节点表为 `h1:2350,h2:2351`，`port = 2351`
- **THEN** `selfIndex == 1`

#### Scenario: 自身不在表中

- **WHEN** 端口不在节点表
- **THEN** 启动失败并打印原因

#### Scenario: 端口重复

- **WHEN** 节点表中有两项端口相同
- **THEN** 启动失败并打印原因

#### Scenario: 环形后继

- **WHEN** 节点数 3、self = 2、backup = 2
- **THEN** 后继为 `[0,1]`

#### Scenario: 不与自身建连

- **WHEN** 请求本机下标的客户端
- **THEN** 返回 `None`

### Requirement: 备份副本复制

当 `mqServer_backup > 0` 时，发布成功后 SHALL 异步把记录与其状态推送给环形后续的 `backup` 个节点；
接收方 SHALL 只落盘副本，不投递、不再次备份。批量 SHALL 在「累积 64 条」或「距上次 100ms」时触发；
队列有界，溢出时 SHALL 丢弃并记 WARN，不得阻塞发布。

#### Scenario: 目标为环形后继

- **WHEN** self = 0、节点数 3、backup = 2
- **THEN** 只向节点 1、2 发送

#### Scenario: backup 为 0

- **WHEN** `mqServer_backup = 0`
- **THEN** 不发送任何备份消息

#### Scenario: 按条数或时间 flush

- **WHEN** 累积到 64 条，或注入时钟前进 100ms
- **THEN** 各触发一次发送，载荷记录条数正确

#### Scenario: 队列满不阻塞

- **WHEN** 备份队列达到上限
- **THEN** 新记录被丢弃并记 WARN，发布调用立即返回

#### Scenario: 副本不参与消费

- **WHEN** 接收方收到备份消息
- **THEN** 只写入备份目录，本队列与订阅表均无变化

#### Scenario: 单节点故障不影响其它

- **WHEN** 后继节点 1 不可达、节点 2 可达
- **THEN** 节点 2 仍收到副本

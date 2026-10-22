# fmq 服务端运行时（delta）

## ADDED Requirements

### Requirement: 生产产物与测试替身的边界

测试基础设施 SHALL NOT 被编入生产产物：

- `f_mq` 的 `MQStubServer` SHALL 位于 `MQStubServer_test.cj`，使 `cjpm` 只在测试目标中编译；
  MUST NOT 声明为 `public`。
- `fmq` 的 `TestDirs` SHALL 作为**跨包共享 helper** 保留在非 `_test.cj` 文件
  （`cjpm` 不允许跨包 `import` 他包的 `_test.cj`），可见性 SHALL 为模块内
  （`protected`）——仓颉的 `internal` 只覆盖当前包及子包，而 `fmq.test` 与 `fmq.queue`
  是兄弟包，`internal` 无法被其他包的用例引用。MUST NOT 声明为 `public`。
- 测试替身 MUST NOT 在模块加载/构造阶段注册进程级钩子（如 `atExit`）；临时目录由用例在
  `@AfterAll` 中调用 `TestDirs.cleanNamespace` 回收。
- 生产源集（非 `*_test.cj`）MUST NOT 引用测试替身；`fmq` 主程序 MUST NOT 链接 `TestDirs`。

#### Scenario: 动态库不含测试替身

- **WHEN** 构建 `f_mq` 动态库并检索符号
- **THEN** 不存在 `MQStubServer` 的公开符号

#### Scenario: 可执行文件不链接测试目录

- **WHEN** 构建 `fmq` 并检索 `bin/main` 的符号与字符串
- **THEN** 不存在 `TestDirs` 符号（`cjpm` 仍会编译 `fmq.test` 包，但它不进入主程序）

#### Scenario: 模块外不可见

- **WHEN** 其他模块的源码 `import fountain::fmq.test.TestDirs`
- **THEN** 构建失败（`protected` 只在模块内可见）

#### Scenario: 生产源集不引用

- **WHEN** 检索 `fmq/src` 与 `f_mq/src` 中引用 `TestDirs` / `MQStubServer` 的文件
- **THEN** 全部以 `_test.cj` 结尾

### Requirement: 服务端侧的受支持面

服务端代码 SHALL 删除无生产消费者且无语义价值的符号与分支：

- `SubscriberRegistry.removeByBuffer`：生产已改用「订阅 id + generation」清理，该方法 SHALL 删除或
  下沉到测试工具；MUST NOT 在详细设计中被称为生产清理入口。
- `MQSubscriptionInfo.isConnected` 这类只写不读的访问器 SHALL 删除。
- `MQManager` 的 `case _`（未知子命令）与 `main.cj` 的 `--help` 分支是**可达**的兜底/帮助路径，
  SHALL 保留；只有真正不可达的分支才删除（以编译器与用例判定）。
- `QueueManager.hasLocalQueues` 若无生产读取方，SHALL 删除或接入日志/指标。

#### Scenario: 断链清理只有一条生产路径

- **WHEN** 检索 `removeByBuffer` 的调用点
- **THEN** 生产路径为 0；清理只经 `cleanupSubscribers()`（按 id + generation）

#### Scenario: 无不可达分支

- **WHEN** 对子命令解析与消息分派做穷尽 match
- **THEN** 不存在编译期即可证明不可达的 `case _`

## MODIFIED Requirements

### Requirement: 启动装配与关闭

启动顺序 SHALL 严格为：

1. 读取并校验配置；
2. 打开本机队列（`QueueManager`）；
3. 启动清理、备份、反熵等定时器与工作线程；
4. **最后**绑定端口并开始监听。

端口绑定 MUST NOT 发生在构造 `MQServer` 时；构造阶段失败（如清理器初始化抛错）MUST NOT 留下
已占用端口。`Server` 的构造/绑定 SHALL 延迟到 `start()` 的监听步骤。
开启备份时，从「队列已打开」到「监听起来」之间 MUST NOT 接受发布请求，避免出现「请求已接受但
备份未运行」的窗口。

关闭 SHALL 按与启动相反的顺序执行，完整列表为：
server → cleanupTimer → antiEntropy → backup → cleaner → consume → subscribers →
backupStore → **queues.sync** → queues → deadLetter → meta → registry。
单步失败 SHALL 记录失败步骤并继续其余步骤；再次 `close()` SHALL 只重试失败步骤。
`queues.sync()` 是独立步骤，SHALL 有用例断言它确实被调用（注入观测点或替身）。

#### Scenario: 只打开本机队列

- **WHEN** 启动服务端
- **THEN** 只为自身端口持有的队列建目录

#### Scenario: 关闭后可重新绑定

- **WHEN** `close()` 后再次启动
- **THEN** 端口可重新绑定

#### Scenario: 无法连接任何 peer 仍可启动

- **WHEN** 所有 peer 不可达
- **THEN** 服务端仍完成启动并接受本机请求

#### Scenario: 重启恢复消费

- **WHEN** 关闭后重启
- **THEN** 未确认消息可继续消费

#### Scenario: 收到 SIGTERM 完整关闭

- **WHEN** 收到 `SIGTERM`
- **THEN** 退出钩子执行完整关闭序列

#### Scenario: 关闭中途失败

- **WHEN** 某一步抛异常
- **THEN** 其余步骤仍执行，失败步骤被记录

#### Scenario: run 可返回

- **WHEN** 触发关闭
- **THEN** `run()` 返回，不永久阻塞

#### Scenario: 定时器先于监听

- **WHEN** 用注入点记录「定时器启动」与「端口可连接」的先后
- **THEN** 定时器启动在前；监听前有连接尝试时连接被拒绝

#### Scenario: 装配失败不占端口

- **WHEN** 清理器或备份装配抛错
- **THEN** 端口未被绑定，进程以非 0 退出

#### Scenario: 关闭时 sync 队列

- **WHEN** 执行 `close()`
- **THEN** `queues.sync()` 被调用一次且失败会被记录为失败步骤

### Requirement: 子命令分发

顶层 SHALL 支持 `server` 与 `manager` 两个子命令；`manager` SHALL 支持 **7 个**子命令：
`registerTopic`、`registerSubscriber`、`listTopics`、`listSubscribeGroups`、
`deleteSubscribeGroup`、`deleteTopic`、`stats`。
帮助文本、README、详细设计、源码注释与用例中的数量 SHALL 统一为 7，MUST NOT 残留「六个」。

#### Scenario: 顶层帮助

- **WHEN** 运行 `fmq --help`
- **THEN** 列出 `server` 与 `manager`

#### Scenario: 管理端帮助

- **WHEN** 运行 `fmq manager --help`
- **THEN** 列出 7 个子命令（含 `stats`），名称与 README 一致

#### Scenario: 未知子命令

- **WHEN** 传入未知子命令
- **THEN** 打印帮助并返回非 0

### Requirement: 命令处理矩阵

服务端 SHALL 对每条命令给出确定的成功/错误结果，MUST NOT 因无法解析而返回 `None`
（客户端会挂起）。至少以下错误分支 SHALL 返回 `ERROR(INTERNAL)` 并记 WARN/ERROR：

1. `SUBSCRIBE` 的 tags 非法 → `INVALID_TAGS`；
2. `SUBSCRIBE` 时本机没有该主题队列 → `NOT_OWNER`；
3. `REGISTER` 收到意外载荷类型；
4. 内部信封的未知 `kind`；
5. `PUBLISH` 收到非 `backup` 的内部信封；
6. `META_SYNC` 收到未知子载荷。

#### Scenario: 注册返回分配

- **WHEN** 收到合法 `REGISTER`
- **THEN** 返回主题分配

#### Scenario: 非法主题

- **WHEN** 主题不是绝对路径
- **THEN** 返回 `INVALID_TOPIC`

#### Scenario: 发布原样落盘

- **WHEN** 收到合法 `PUBLISH`
- **THEN** 记录落盘并可读回

#### Scenario: 未注册组

- **WHEN** 消费未注册组
- **THEN** 返回 `GROUP_NOT_EXIST`

#### Scenario: 空消费不是错误

- **WHEN** 队列为空
- **THEN** 返回成功且无记录

#### Scenario: 内部同步与备份分派

- **WHEN** 收到 `metaSync` / `backup` 内部信封
- **THEN** 分别执行元数据同步与备份落盘

#### Scenario: 垃圾载荷

- **WHEN** `PUBLISH` 载荷无法解析
- **THEN** 返回 `ERROR(INTERNAL)`，不 panic

#### Scenario: 六条错误分支

- **WHEN** 依次触发上文 1–6
- **THEN** 每条都返回规定的错误码，日志含命令与原因，客户端不挂起

### Requirement: 服务端配置项与默认值

配置读取 SHALL 全部走 `Config.getString` + 严格解析（`strictPort`/`strictInt64`/`strictDuration`），
MUST NOT 使用 `?? 默认值` 静默回落；只有 `nodes` 项的 host 解析使用 `MQHost.parseHost`。
`validate()` SHALL 覆盖：端口非 0、各时长 > 0、`segmentedLogMaxSize > 0`、`backup >= 0`、
节点表非空且每项合法、非本机端口不重复、备份数不超过节点数。
帮助文本 SHALL 列出全部 12 个配置项，并给出默认值文本。

「默认值」用例 SHALL 在**不写入任何键**的前提下断言解析结果（真正走 `None` → 默认值分支），
不得先把 11 个键显式写成默认值再断言。

#### Scenario: 默认值

- **WHEN** 配置中不存在任何 `mqServer_*` 键（节点表除外）
- **THEN** 解析结果为文档默认值（端口 2350、ack 超时 10s、段上限 1G 等）

#### Scenario: 环境变量覆盖

- **WHEN** 设置同名环境变量
- **THEN** 覆盖默认值

#### Scenario: 帮助文本完整

- **WHEN** 运行 `fmq server --help`
- **THEN** 输出含 12 个配置项名与各自默认值（含 `mqServer_tombstoneTTL`、
  `mqServer_antiEntropyInterval`）

#### Scenario: 非法值不回落

- **WHEN** 配置项不是合法数字/时长
- **THEN** 启动失败并指出键名与值

#### Scenario: 端口 0

- **WHEN** `mqServer_port = 0`
- **THEN** 启动校验失败，错误信息指出端口不得为 0

#### Scenario: 段上限与记录上限不匹配

- **WHEN** `mqServer_segmentedLogMaxSize` 小于 64 MiB + 4
- **THEN** 启动成功但记 WARN，说明单条记录上限被压低到 `maxFileSize - 4`

### Requirement: 服务端测试资产

服务端测试 SHALL 满足：

- 用例 MUST NOT 只断言退出码；管理端与配置相关用例 SHALL 同时断言输出文本或状态变更；
- 「发布触发备份」SHALL 有用例：`backup >= 1` 时发布一条，注入的备份替身收到一次入队；
- 退出钩子：`runServer()` 的 `toExitGracefully()` 调用 SHALL 可观测；
  `fmq manager ...` SHALL NOT 注册 MQ 退出钩子；
- 进程级 `Config` 的写入 SHALL 经统一沙箱（记录键的原始存在性与值，用例结束恢复/删除）；
- 关闭相关用例 SHALL 断言 `queues.sync()` 被调用；
- 配置缺失、命令矩阵错误分支、`port = 0` SHALL 各有用例。

#### Scenario: 内部变更落地

- **WHEN** 运行服务端测试
- **THEN** 每个用例的开始/结束状态可独立复现

#### Scenario: 发布触发备份

- **WHEN** `backup = 1` 且发布一条记录
- **THEN** 备份替身恰好收到一次入队（topic、queueIndex、位置、字节一致）

#### Scenario: 关闭释放

- **WHEN** `MQServer.close()`
- **THEN** 订阅表清空、`queues.sync()` 被调用、端口可重新绑定

#### Scenario: manager 不安装钩子

- **WHEN** 执行 `fmq manager listTopics`
- **THEN** 退出钩子注册计数为 0；`fmq server` 为 1

#### Scenario: 配置隔离

- **WHEN** 用例修改任意 `mqServer_*` / `mqClient_hosts` 键
- **THEN** 结束后键的存在性与值与修改前完全一致

### Requirement: 备份存储关闭并发安全

`BackupStore.close()` 与 `append` 并发时 MUST NOT 崩溃；关闭前成功返回的写入 SHALL 可读回。
关闭后到达的写入 SHALL 被安全丢弃并**留痕**：记 DEBUG 或 WARN（同一秒内限流一条），
含 topic/queueIndex/位置；MUST NOT 完全静默。README 与本规格 SHALL 使用同一表述。

#### Scenario: 关闭与写入并发

- **WHEN** 一个线程 `close()`，另一个线程持续 `append`
- **THEN** 不崩溃；部分写入成功，部分被丢弃并留痕

#### Scenario: 关闭前写入可读回

- **WHEN** `append` 在 `close()` 前成功返回
- **THEN** 关闭后从磁盘可读回

#### Scenario: 关闭后写入

- **WHEN** `close()` 返回后 `append`
- **THEN** 返回成功（或明确异常，二选一并写入规格），日志有 DEBUG/WARN 留痕

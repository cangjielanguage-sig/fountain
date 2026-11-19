# R7：通道 / Supervisor 专项

审查时间：2026-11-06（只读）

## 审查范围

`src/channel/{ChannelMediator,ChannelContract,ChannelBootstrap,EmailChannel,ChannelFunctions}.cj`（含 4 个测试）；
`src/loom/{Supervisor,LoomWiring,LoomBootstrap,LoomService}.cj` 及 `LoomWiringSupervisor_test.cj`；
交叉核对 `f_data/src/json/JsonValue.cj`（`JsonString.toString()` 转义正确）、`tool/FunctionResult.cj:46-48`。

## 发现

### [严重] 附件落盘文件名未净化，存在路径穿越 / 任意文件覆盖

- **位置**：`src/channel/EmailChannel.cj:76`、`:92`、`:113-115`
- **描述**：`freeName` 直接 `${directory}/${filename}` 拼接；`filename` 来自远端邮件，含 `../` 即可写出下载目录；`save` 只判 `exists(dir)`，不校验是否为目录，也不校验最终路径仍在 `dir` 下，`File.create` 是截断写。
- **建议**：取纯文件名（剥离目录段），拒绝空名/`.`/`..`/分隔符/Windows 保留名；落盘后 canonicalize 断言前缀；越权记审计。

### [严重] `channelSend` 附件路径无访问约束，模型可外发宿主任意可读文件

- **位置**：`src/channel/EmailChannel.cj:156-160`、`src/channel/ChannelFunctions.cj:82-90`
- **描述**：发送侧只 `exists(Path(path))`，不校验普通文件、无目录白名单；工具参数写着「绝对路径」且由模型调用，提示注入即可外发 `~/.ssh/id_rsa`、渠道配置。仓库内 `WebFetchFunction` 已有 `SsrfGuard`，此处无对齐防线。
- **建议**：增加允许根目录（默认空 = 禁用附件），校验 canonical 前缀 + `isRegular()`，拒绝符号链接。

### [严重] `AttachmentSink` 的「先探测再创建」存在 TOCTOU，可能静默覆盖已有附件

- **位置**：`src/channel/EmailChannel.cj:113-116`
- **描述**：`exists` 探测与 `File.create` 非原子且 create 截断；并发两个 `channelInbox` 可能得到同一 free 名，后者覆盖前者，与「不覆盖已有文件」承诺相反。
- **建议**：改为独占创建 + 冲突重试（把命名与创建合成一个原子动作）。

### [一般] `FEmailTransport.receive` 吞掉所有异常，配置错误被伪装成「0 封邮件」

- **位置**：`src/channel/EmailChannel.cj:267-271`
- **描述**：IMAP 未开/密码错/主机不可达/TLS 失败全部变空列表，`channelInbox` 返回 `[]` 而非 `ok:false`；与 send 的错误语义不对称，轮询流程会永久静默失效。
- **建议**：首封前失败抛 `ChannelException`，由 `channelInbox` 转 `ok:false`；仅「已取到部分后 body 失败」才降级回传。

### [一般] 单条附件读取失败会中断整批收信

- **位置**：`src/channel/EmailChannel.cj:173`、`:260-262`
- **描述**：`item.read()` 抛异常会穿透到 `channelInbox` 的 catch，整批消息丢弃，结果退化为一条 `ok:false`。
- **建议**：按附件粒度 try/catch，失败产出 `InboundAttachment(error: ...)`。

### [一般] 实例登记：覆盖不关闭、无 `close` 入口、空账号实例互相覆盖

- **位置**：`src/channel/ChannelMediator.cj:96-101`、`:194-206`；全仓无 `Channel.close()` 调用点
- **描述**：(a) `register` 覆盖旧实例不 `close`，重复 `wire`/`install` 泄漏 `Email` 连接；(b) 键含空账号，两个 `account=''` 实例静默互相覆盖；(c) `Mutex` 覆盖完整，但 `FEmailTransport.client` 是无锁 `var`，并发 send/close 有竞争。
- **建议**：覆盖时 close 旧实例或提供显式 replace；加 `closeAll()`；空账号重复注册抛错；transport 懒建连加实例锁。

### [一般] `ChannelBootstrap` 解析：`null` 变字面量 "null"、端口截断不校验、必填项不校验

- **位置**：`src/channel/ChannelBootstrap.cj:88-96`、`:98-109`、`:68-73`
- **描述**：(a) `JsonNull.toString()` 是 `"null"`，`{"account":null}` 会注册出账号名 `null`；(b) `UInt16(70000)` 静默截断为 44672，`"abc"` 静默回退 465；(c) `smtpHost`/`user` 为空也计入 installed，发信时才炸。
- **建议**：`strOf` 显式处理 `JsonNull`；端口越界记 skipped；email 平台强校验必填项。

### [一般] `tls` 与 `extra` 解析后无人消费，配置项形同虚设

- **位置**：`src/channel/ChannelContract.cj:146-147`、`:161-162`、`src/channel/ChannelBootstrap.cj:72`
- **描述**：`tls`/`extra` 读入但全仓无读取点；用户写 `"tls":"starttls"` 不改变行为，易误以为已加固。
- **建议**：接到 `Email.builder()`，或从契约移除并在文档标注「暂不支持」。

### [一般] `dispatch` 二次校验失败后不摘除陈旧路由，选路阶段仍有可外抛的存储调用

- **位置**：`src/loom/Supervisor.cj:179-181`、`:167`
- **描述**：(a) 状态漂移时只返回 `NO_USABLE`，不 `unregister`/不刷新，路由永久留在候选里反复被选中、反复白烧 LLM；(b) `service.status()` 在 try 外，存储不可用时异常穿透，与「选路任何异常都按无可用处理」的契约冲突。
- **建议**：漂移时同步路由（register 新状态或 unregister）后返回，并可区分 `stale`；把 `routable()/status()` 纳入 try。

### [一般] `auto-*` 命名是 check-then-act，并发下覆盖已有流程

- **位置**：`src/loom/Supervisor.cj:198`、`:222-235`
- **描述**：`nextFlowName` 锁外循环探测，随后才 `execute`；同秒内两个 dispatch 得到同名，第二次 `registry.put` 覆盖第一条流程。
- **建议**：命名+占位放同一临界区，或用「已存在则失败」的 create 语义并重试。

### [一般] `restoreFailed` 在装配路径上是死信号

- **位置**：`src/loom/LoomWiring.cj:67`、`src/loom/LoomBootstrap.cj:23-31`
- **描述**：`wire` 丢弃 `ReloadResult`，`toString()` 也不打印该字段；生产上「库晚就绪」时应用照常启动、路由表静默为空、无任何日志。
- **建议**：`wire` 接收并 warn/暴露状态；`toString()` 补字段。

### [一般] `ChannelBootstrap.installFromConfig()` 未加保护，通道配置异常可中断整个 loom 装配

- **位置**：`src/loom/LoomWiring.cj:78`、`src/channel/ChannelBootstrap.cj:84-86`
- **描述**：`LLMConfig.channelsJson()` 在 install 的 try 之外求值，配置源读取异常直接抛出 `wire()`，导致后续 Supervisor/SkillCatalog/演进等全部不执行。
- **建议**：`installFromConfig` 内部 try 转 report.errors；`wire` 再包一层 try。

### [一般] 装配顺序：`wire` 覆盖调用方已装的 host，Supervisor 可能绑到与执行路径不一致的宿主

- **位置**：`src/loom/LoomWiring.cj:76`、`:111-114`
- **描述**：`installHost` 无条件覆盖，自定义 host 永远不生效；`LoomServices` 静态态为裸 `static var` 无锁。
- **建议**：`installHost` 已存在则不覆盖，或 `wire` 接受可选 host；`Supervisor.install` 先播种再发布。

### [建议] 收尾问题（合并）

- `src/channel/EmailChannel.cj:90-97`：`while(true)` 之后的 `filename` 是死代码；同名探测 O(n)。
- `src/loom/Supervisor.cj:167-173`：候选为空仍调一次 LLM，应短路。
- `src/loom/Supervisor.cj:270-277`：选路结果只判空不 trim，`" daily "` 选不中。
- `src/channel/ChannelFunctions.cj:96/127/129`：成功返回对象、收信返回数组、失败又返回对象，形状不一致；`limit` 无上限；错误回显底层 `e.message`（含主机名），建议脱敏。
- `src/channel/ChannelMediator.cj:104-131`：`platforms/accounts` 在锁内 `contains` 去重 O(n²)；`resetAll()` 为 public，生产误调会永久清掉静态注册的 email provider。

## 统计

| 严重 | 一般 | 建议 |
|---|---|---|
| 3 | 9 | 1（含 5 处） |

**总评**：中介者的键归一化与锁覆盖范围干净，`ChannelBootstrap` 单条失败隔离、`Supervisor` 的锁分层与幂等实现准确，测试覆盖到位（非法 JSON、空名、未知名、状态漂移、撞名顺延）。最大短板是**安全边界**：附件落盘信任远端文件名、发送侧可指定任意本地路径、freeName→create 的 TOCTOU。其次是可观测性成对问题：`receive` 吞异常与 `restoreFailed` 被装配层丢弃。Supervisor 剩余问题集中在路由漂移与 `auto-*` 无锁命名。架构方向正确，不需要重构。

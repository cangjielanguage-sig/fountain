# Design

## Context

动机见 `proposal.md`。已核对的事实：

- `f_email`（同仓模块）提供 `Email` 门面：`Email.builder().smtp(host, port).imap(host, port).auth(user, Secret.of(pwd)).build()`、`send(MailMessage): SendReport`、`list(limit): Array<MailSummary>`、`body(MailSummary): MailBody`、`delete`、`close`；IMAP 用 EXAMINE，**不置已读**。
- `f_llm` 里没有任何站外消息能力（grep `email|smtp|wechat|dingtalk|feishu` 零命中），全仓也没有 `Channel` / `Notifier` 抽象。
- 工具注册靠 `@Bean` + `FunctionCalling<T>`，`FunctionMediator.ensureLoaded()` 扫描 bean；`FunctionCalling` 要求 `prop name` / `prop description` / `func call(json)`。
- 「静态块注册」在本仓的既有写法是文件顶层 `let _x = Stores.registerContent(...)`（`store/ContentStore.cj:217`），Cangjie 无 static initializer 语法。

## Goals / Non-Goals

**Goals:**

- 平台无关：业务只看到 `(platform, account)` + 统一消息结构。
- 扩展成本低：新增平台 = 一个 `Channel` 实现 + 一行静态注册。
- 流程内可用：loom 的 JIT 步骤与模型工具循环都能发、能收。
- 离线可测：所有单测不连真实 SMTP/IMAP。

**Non-Goals:**

- 不做消息路由器 / 订阅（“收到某类消息触发流程”不在本期）。
- 不做微信 / 企业微信 / 钉钉 / 飞书的协议实现。
- 不做附件下载与收发（本期只处理文本与 HTML 正文）——`f_email` 有能力，但先不暴露，避免一次吞太多。
- 不做凭据加密存储（沿用环境变量 / 配置文件，与 f_llm 其它配置一致）。

## Decisions

### D1. 新包 `fountain::f_llm.channel`，不动既有包

`channel/ChannelContract.cj`（接口与消息模型）、`ChannelMediator.cj`（中介者 + provider 表）、`EmailChannel.cj`（邮件实现）、`ChannelBootstrap.cj`（配置装配）、`ChannelFunctions.cj`（两个工具）。

**替代**：塞进 `tool/`。否决——工具只是访问入口之一，业务里也可能直接调中介者；放在 `tool` 会让「通道」依赖「工具」。

### D2. 两段式注册：provider 走静态块，实例走启动装配

```cangjie
// EmailChannel.cj 顶层（模块加载即执行）
let _emailProviderRegistered = ChannelProviders.register('email', { conf => EmailChannel.fromConf(conf) })
```

- **provider**（平台名 → 工厂）用顶层 `let` 自动注册：满足「实现自己登记自己」，且不需要配置就能枚举平台；
- **实例**（真正能发消息的对象）由 `ChannelBootstrap.install()` 读 `llm_channels` 逐条创建并 `ChannelMediator.register(channel)`：账号是运行期数据，不该编进静态块。

**替代**：静态块直接创建实例。否决——静态块执行时配置可能还没就绪，且单测会被真实账号污染，必须额外加 reset 逻辑。

### D3. 寻址键 `(platform, account)`，空账号取默认

`ChannelMediator.channel(platform, account)`：`account` 为空时，若该平台恰好只有一个实例则返回它，否则抛异常（避免「猜一个账号」）。

键归一化：`platform`、`account` 均 `trimAscii().toAsciiLower()`，注册与查询用同一套规则。

### D4. 消息模型覆盖文本与附件（附件按文件路径）

```cangjie
public class OutboundMessage { to/subject/text/html/attachments: ArrayList<OutboundAttachment> }
public class OutboundAttachment { filename/path }        // 以本地文件路径给出，不搬字节
public class InboundMessage  { id/from/subject/text/receivedAt/unread/attachments: ArrayList<InboundAttachment> }
public class InboundAttachment { filename/size/path/saved/error }  // saved=false 时 error 说明原因
public class SendReceipt     { ok/messageId/error }
```

- 发送侧用**路径**而非字节：邮件正文与附件都可能很大，进程内搬一遍没有收益；路径由调用方保证存在，不存在时按 spec 直接失败。
- 接收侧附件默认只给元数据，`downloadDir` 非空时落盘并回填 `path`；同名冲突用 `name-2.ext` 顺延，不覆盖已有文件。

**替代**：直接把 `f_email` 的 `MailMessage` 暴露成通用模型。否决——平台无关接口不能依赖某个平台的类型。
**替代**：附件用 `Array<Byte>` 传。否决——会把大对象塞进 JSON 工具返回值，`llm_toolResultMaxBytes` 会先把它截断。

### D5. `EmailChannel` 依赖可注入的 `EmailTransport`

```cangjie
public interface EmailTransport {
    func send(message: OutboundMessage, from: String): SendReceipt
    func inbox(limit: Int64, downloadDir: String): ArrayList<InboundMessage>
    func close(): Unit
}
```

生产实现 `FEmailTransport` 内部持 `f_email.Email`（发送走 `attach(name, FileBodySource(path))`，接收走 `body(summary).attachments` + `saveTo`）；
单测注入假实现，断言「映射对不对」与「落盘命名冲突顺延」，不碰网络、不碰真实磁盘目录（用临时目录）。

**替代**：直接调 `Email`。否决——单测就要连真服务器，等于没测。

### D6. 配置项 `llm_channels`

```json
[
  {"platform":"email","account":"work",
   "from":"bot@example.com","user":"bot@example.com","password":"***",
   "smtpHost":"smtp.example.com","smtpPort":465,
   "imapHost":"imap.example.com","imapPort":993}
]
```

解析用 `JsonValue.fromStr(...).asArray()` 逐条读；**单条非法只跳过该条并记 `warn`**，不中断启动——这与「配置只读、启动一次」的既有约束一致，也符合 spec 的「配置非法」场景。

### D7. loom 集成用两个工具，不新增网关 kind

`channelSend` / `channelInbox` 走既有工具链路：JIT 步骤 `loomCallTool("channelSend", …)`、模型工具循环直接调用。**不**扩 `loomStore` 的 kind——那是存储网关，消息发送有副作用，混进去会让「读存储」和「发消息」在审计上无法区分。

工具返回 JSON 字符串；平台不支持时返回 `{"ok":false,"error":"channel platform not supported: wecom"}` 这类文本，而不是抛异常（与 `CurrentTimeFunction` 参数非法时的处理一致）。

### D8. 未实现平台只留常量，不注册 provider

`ChannelPlatforms` 定义 `EMAIL='email'` / `WECHAT='wechat'` / `WECOM='wecom'` / `DINGTALK='dingtalk'` / `FEISHU='feishu'` 供调用方与将来实现引用，但只有 `email` 进 provider 表。`platforms()` 只返回已实现的。未实现平台在 `send` 时报「not supported」。

## Risks / Trade-offs

| 风险 | 缓解 |
|---|---|
| 凭据以明文配置存在 | 与仓库其它配置同源（环境变量/配置文件），文档标注；后续可接 Secret 体系 |
| IMAP 拉信是同步阻塞 | 只在流程步骤里调用，已有 `LoomTimeout` 兜底；文档写明超时配置 |
| 多账号配置写错难排查 | 单条失败只跳过并 `warn`，`platforms()/accounts()` 可自查实际生效情况 |
| 平台差异大（IM 无标题、邮件无会话） | 通用模型取交集（to/subject/text），平台特有字段放各自实现内部，不污染接口 |

## Migration Plan

新增能力，默认无实例（`llm_channels` 未配置时中介者只有 provider），不改变任何既有行为；回退只需移除配置项。

## Open Questions

- 接收侧是否需要「增量游标」（只取上次之后的新邮件）：`f_email.list` 目前按数量拉取，本期用数量 + 去重交给调用方；如果流程要「只看新邮件」，再补 `since` 语义。

# Spec Delta

## Purpose

为第三方消息平台（邮件、微信、企业微信、钉钉、飞书等）提供平台无关的发送与接收接口，并允许业务代码与 loom 流程按「平台 + 账号」寻址访问，而不必了解各平台的协议差异。

## ADDED Requirements

### Requirement: 平台接入接口

系统 SHALL 提供平台无关的消息通道接口，包含发送、接收、关闭三项能力；发送入参 MUST 至少覆盖收件人、标题、正文，接收结果 MUST 至少cover 消息标识、发件人、标题、正文、接收时间。

#### Scenario: 实现一个平台

- **WHEN** 某个平台实现类实现该接口并提供平台名与账号名
- **THEN** 它可被中介者登记，业务代码无需感知其协议细节

### Requirement: 中介者按平台与账号寻址

系统 SHALL 通过中介者统一访问所有通道，以平台名为一级键、账号名为二级键；同一平台 MUST 支持注册多个账号；账号名留空时 MUST 落到该平台的默认账号。

#### Scenario: 同平台多账号

- **WHEN** 注册了 `email` 平台的 `work` 与 `personal` 两个账号
- **THEN** 按 `(email, work)` 与 `(email, personal)` 可分别取到不同通道，`accounts("email")` 同时列出两个账号

#### Scenario: 默认账号

- **WHEN** 账号名留空且该平台只注册了一个账号
- **THEN** 返回该账号的通道

#### Scenario: 未知平台或账号

- **WHEN** 请求的 `(platform, account)` 未注册
- **THEN** 抛出明确异常（含平台名与账号名），不静默返回空通道

### Requirement: 静态块自动注册平台

每个平台实现 MUST 在模块加载时自动向中介者注册自己的 provider（平台名 → 工厂），无需业务方手工登记；注册项 MUST 可枚举，重复注册同名平台 MUST 幂等。

#### Scenario: 模块加载后平台可枚举

- **WHEN** 进程加载 f_llm 且未做任何手工注册
- **THEN** `platforms()` 至少包含 `email`

#### Scenario: 重复注册

- **WHEN** 同一平台名被注册两次
- **THEN** provider 表仍只有一项，后一次不覆盖先一次的行为

### Requirement: 配置驱动的实例装配

系统 SHALL 支持通过配置项 `llm_channels`（JSON 数组，每条描述一个账号）在启动时创建通道实例并登记；配置缺省或为空 MUST 保持「只有 provider、没有实例」的状态，不影响其它能力。

#### Scenario: 配置一个邮箱账号

- **WHEN** `llm_channels` 含一条 `email` 账号配置并执行装配
- **THEN** 中介者中可查到该平台账号，可直接发送

#### Scenario: 配置非法

- **WHEN** `llm_channels` 不是合法 JSON 数组或缺少必要字段
- **THEN** 该条配置被跳过且不影响其它账号，装配本身不抛错中断启动

### Requirement: 电子邮件发送

系统 SHALL 基于 `f_email` 实现邮件通道的发送：按账号配置的 SMTP 主机与凭据发信，支持携带附件（以本地文件路径给出），返回结果 MUST 指明是否成功及失败原因。

#### Scenario: 成功发送

- **WHEN** 对已配置账号发送一封含收件人、标题、正文、若干附件的邮件
- **THEN** 通道调用 SMTP 发送并把成功结果返回给调用方，附件随信投递

#### Scenario: 发送失败

- **WHEN** SMTP 拒绝或网络异常
- **THEN** 返回失败结果并携带错误信息，不抛出未捕获异常给流程

#### Scenario: 附件文件不存在

- **WHEN** 指定的附件路径不存在或不可读
- **THEN** 该次发送返回失败并指明是哪个文件，不发出缺附件的邮件

### Requirement: 电子邮件接收（含附件）

系统 SHALL 基于 `f_email` 实现邮件通道的接收：按数量拉取最近邮件，返回标识、发件人、标题、正文、接收时间与附件清单；调用方给出下载目录时 MUST 把附件落盘到该目录并在结果中给出路径；接收 MUST NOT 改变服务端的已读状态。

#### Scenario: 拉取最近邮件

- **WHEN** 对已配置账号请求最近 N 封邮件
- **THEN** 返回不超过 N 条消息，每条含标识、发件人、标题、正文与接收时间

#### Scenario: 附件元数据

- **WHEN** 邮件带 2 个附件且未指定下载目录
- **THEN** 结果中列出两个附件的文件名与大小，不落盘

#### Scenario: 附件落盘

- **WHEN** 指定下载目录且附件可读
- **THEN** 附件被写入该目录，结果中给出本地路径，原文件名冲突时 MUST 不覆盖已有文件

#### Scenario: 附件不可写

- **WHEN** 下载目录不存在或不可写
- **THEN** 该封邮件的附件标记为未下载并携带原因，正文与其它邮件照常返回

#### Scenario: 不置已读

- **WHEN** 拉取邮件后再次拉取
- **THEN** 邮件的已读状态与拉取前一致

### Requirement: loom 流程内可访问

系统 SHALL 提供 `channelSend` 与 `channelInbox` 两个工具，使 loom 流程可经统一入口发送与接收消息；工具参数 MUST 至少包含平台名与账号名，返回值 MUST 为 JSON 字符串。

#### Scenario: 流程内发送

- **WHEN** loom 的 JIT 步骤调用 `channelSend` 并给出平台、账号与消息内容
- **THEN** 消息经中介者投递，步骤拿到包含成功标志的 JSON

#### Scenario: 流程内收信

- **WHEN** loom 步骤调用 `channelInbox` 指定平台、账号与数量
- **THEN** 返回消息数组的 JSON，条目字段与接收结果一致

#### Scenario: 平台未实现

- **WHEN** 调用 `channelSend` 时平台名为预留但未实现的平台（如 `wecom`）
- **THEN** 返回明确的不支持说明文本，不抛出未捕获异常

### Requirement: 未实现平台不做假实现

系统 MUST NOT 为未实现平台提供可调用但不工作的实现；平台名常量 MAY 预先定义，但 `platforms()` / 发送入口 MUST 明确其不可用。

#### Scenario: 预留平台名

- **WHEN** 查询中介者支持的平台
- **THEN** 只列出已实现平台（`email`），预留平台名不出现在可用列表

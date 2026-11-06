# Proposal

## Why

代码审查 R7 在通道模块留下一批「错得不明显」的问题，都属于**该报错却装作正常**：

- `FEmailTransport.receive` 把所有异常吞成空列表：密码错、主机不可达、TLS 失败都表现为「0 封邮件」；
- 单个附件 `read()` 抛异常会中断整批收信，已取到的邮件全丢；
- `ChannelMediator.register` 覆盖同键实例时不 `close` 旧的，也没有 `closeAll()`；空账号重复注册互相覆盖；
- `ChannelBootstrap` 把 `null` 解析成字面量 `"null"`、端口 `70000` 截断成 `44672`、必填项缺失也计为安装成功；
- `tls` 解析后无人消费，是假开关；
- `installFromConfig` 读配置的异常在 `wire` 的 try 之外，能中断整个 loom 装配。

## What Changes

- `receive`：首封之前失败 → 抛 `ChannelException`（由工具层转 `ok:false`）；已取到部分后才失败 → 保留已取部分。
- 单条附件读取失败 → 记在该附件的 `error` 上，继续处理其余附件与邮件。
- `register`：同键覆盖时先 `close()` 旧实例；空账号重复注册直接抛错；新增 `closeAll()`。
- `ChannelBootstrap`：`JsonNull` → 空串；端口必须落在 `1..65535`，否则跳过该条并记错误；email 平台强校验 `from`/`user`/`smtpHost`。
- `tls`：只接受空串或 `ssl`；`starttls` 与其它值明确拒绝并说明「暂未实现」，不再是假开关。
- `installFromConfig` 内部捕获配置读取异常，转成报告里的 error，不向外抛。

## Capabilities

### Modified Capabilities
- `platform-channel`：错误必须显式、配置非法必须跳过并记录、实例替换必须释放旧连接。

## Impact

- 代码：`src/channel/EmailChannel.cj`、`ChannelMediator.cj`、`ChannelBootstrap.cj`。
- 行为：非法 `llm_channels` 条目从「装上一个坏实例」变为「跳过 + 记错」；`tls:starttls` 从「静默忽略」变为「跳过并说明」。
- 测试：新增 8 条（覆盖替换关闭、空账号重复、closeAll、null 字段、端口越界、必填缺失、tls 未实现、附件读取失败不中断）。

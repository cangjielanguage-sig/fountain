# Spec Delta

## Purpose

为服务器监控提供稳定的扩展契约：第三方以「实现一个接口 + 注册一个工厂」的方式增加监控项或告警渠道，宿主程序无需重新编译；同时保证契约模块自身足够轻，扩展作者不必引入 RPC、邮件或 TUI 依赖。

## ADDED Requirements

### Requirement: 监控项契约

系统 SHALL 提供 `ProbeAgent` 接口，包含只读属性 `kind`、`host` 与 `data`。`kind` MUST 是全局唯一且稳定的字符串，作为数据键与配置键；`data` MUST 是 JSON object；`host` MUST 有默认实现并返回空字符串。

#### Scenario: 实现一个监控项

- **WHEN** 扩展类实现 `ProbeAgent` 且只覆写 `kind` 与 `data`
- **THEN** 该实例的 `host` 返回空字符串，注册表可正常登记与查找

#### Scenario: 数据必须是对象

- **WHEN** 某监控项的 `data` 返回非 JSON object
- **THEN** 收集器把该监控项标记为采集失败并记录错误，不把非法数据放进快照，也不影响其它监控项

#### Scenario: 采集抛错

- **WHEN** 某监控项的 `data` 取值抛出 `ProbeException`
- **THEN** 收集器把异常消息写入该监控项的 `error` 字段，其余监控项照常采集

### Requirement: 告警渠道契约

系统 SHALL 提供 `AlarmMessageChannel` 接口，包含 `send(message, receiver)`、`receive()`、`replyConf()` 三个方法。`receive()` MUST 返回一条待处理消息的 JSON 文本或空字符串；`replyConf()` MUST 返回一个配置项名称（不是配置值），该配置项保存允许指挥智能体的账号列表。

系统 SHALL 在同一接口上提供带默认实现的富消息入口 `sendRich(message, html, attachments, receiver)`，默认实现 MUST 退化为调用 `send(message, receiver)`，从而让既有实现无需改动即可编译。

#### Scenario: 仅实现基础方法

- **WHEN** 某渠道只实现 `send` / `receive` / `replyConf`
- **THEN** 调用 `sendRich` 时按纯文本发送，附件与 HTML 被忽略，不抛异常

#### Scenario: 待处理消息格式

- **WHEN** 渠道 `receive()` 返回非空字符串
- **THEN** 该字符串必须是 `{"id":"...","from":"...","subject":"...","body":"..."}` 形式的 JSON object；不符合格式时智能体忽略该消息并记录 WARN

#### Scenario: 没有消息

- **WHEN** 渠道当前没有待处理消息
- **THEN** `receive()` 返回空字符串

### Requirement: 监控项注册表

系统 SHALL 提供进程内线程安全的 `ProbeRegistry`，支持按 `kind` 注册工厂、枚举全部 `kind`、按 `kind` 取工厂。注册 MUST 拒绝重复 `kind`，重复时抛出 `ProbeException`，错误码为 `DUPLICATE`。

#### Scenario: 注册与查找

- **WHEN** 以 `kind="k8s"` 注册一个工厂
- **THEN** `agents()` 包含 `k8s`，`agent("k8s")` 返回该工厂

#### Scenario: 重名拒绝

- **WHEN** 同一 `kind` 被注册两次
- **THEN** 第二次注册抛出 `ProbeException(DUPLICATE)`，注册表仍保留第一次的工厂

#### Scenario: 并发注册

- **WHEN** 多个线程同时注册不同 `kind`
- **THEN** 全部注册成功，`agents()` 的数量与注册次数一致，无数据竞争

### Requirement: 告警渠道注册表

系统 SHALL 提供进程内线程安全的 `AlarmChannelRegistry`，支持按渠道名注册工厂、枚举渠道名、按名取工厂。注册 MUST 拒绝重复渠道名，重复时抛出 `ProbeException`，错误码为 `DUPLICATE`。

#### Scenario: 注册多个渠道

- **WHEN** 注册 `email` 与 `webhook` 两个渠道
- **THEN** `channels()` 同时列出两者，`channel("email")` 与 `channel("webhook")` 返回各自工厂

#### Scenario: 重名拒绝

- **WHEN** 同一渠道名被注册两次
- **THEN** 第二次注册抛出 `ProbeException(DUPLICATE)`，不覆盖已注册工厂

### Requirement: 异常与错误码

系统 SHALL 提供 `ProbeException`（`f_base.BaseException` 子类），至少区分 `DUPLICATE`、`CONFIG`、`LOAD`、`COLLECT` 四类错误码；异常消息 MUST 携带出错对象（`kind`、渠道名或库路径）。

#### Scenario: 错误码可判别

- **WHEN** 捕获到注册重名、配置非法、动态库加载失败、采集失败四种异常
- **THEN** 调用方可以通过错误码区分四类原因，而不是解析文本

### Requirement: 扩展自注册

扩展实现 MUST 能在动态库被加载时自行完成注册，无需宿主手工登记；契约模块 MUST NOT 依赖 `fprobe` 可执行模块。

#### Scenario: 加载即注册

- **WHEN** 宿主加载一个实现了 `ProbeAgent` 并在包初始化时调用 `ProbeRegistry.registerAgent` 的动态库
- **THEN** 加载完成后注册表中出现该扩展的 `kind`

#### Scenario: 契约模块依赖收敛

- **WHEN** 检查 `f_probe` 的依赖
- **THEN** 只有 `f_base` 与 `f_data`，不含 `f_rpc`、`f_email`、`f_llm` 或 TUI 依赖

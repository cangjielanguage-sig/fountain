# Spec Delta

## ADDED Requirements

### Requirement: 收信失败必须显式

拉取邮件时，若一封都没取到就失败，通道 MUST 抛出可读异常（由工具层转成 `ok:false`），MUST NOT 返回空列表冒充「没有邮件」；若已取到部分邮件后才失败，MUST 保留已取部分。

#### Scenario: 认证失败

- **WHEN** IMAP 主机不可达或密码错误，且尚未取到任何邮件
- **THEN** `receive` 抛出异常，`channelInbox` 返回 `ok:false` 与原因

#### Scenario: 部分成功后失败

- **WHEN** 已成功取到 3 封，第 4 封读取正文失败
- **THEN** 返回前 3 封，不抛异常

### Requirement: 单条附件失败不中断整批

某一封邮件里某个附件读取或落盘失败时，MUST 只把该附件标记为失败并携带原因，MUST 继续处理其余附件与邮件。

#### Scenario: 附件读取抛异常

- **WHEN** 附件内容读取抛异常
- **THEN** 该附件 `saved=false` 且 `error` 说明原因，同批其它邮件与附件照常返回

### Requirement: 实例替换与释放

`register` 覆盖同键实例时 MUST 先 `close()` 旧实例；账号为空的实例重复注册 MUST 报错；系统 MUST 提供一次性关闭全部实例的入口。

#### Scenario: 同键替换

- **WHEN** 用同一 `(platform, account)` 再次注册
- **THEN** 旧实例被 `close()`，新实例生效

#### Scenario: 空账号重复

- **WHEN** 两个实例都用空账号注册同一平台
- **THEN** 第二次注册抛错，提示必须显式指定 account

#### Scenario: 全部关闭

- **WHEN** 调用 `closeAll()`
- **THEN** 每个已注册实例都被 `close()`，注册表清空

### Requirement: 配置解析的严格化

装配时 MUST 把 JSON `null` 当作空串；端口 MUST 校验在 `1..65535`；email 平台 MUST 校验 `from`/`user`/`smtpHost` 非空；`tls` MUST 只接受空串或 `ssl`。任一条不满足 MUST 跳过该条并记录错误，MUST NOT 装上一个坏实例。配置读取本身抛异常时 MUST 转成报告里的错误，MUST NOT 中断装配。

#### Scenario: null 字段

- **WHEN** `{"account": null, ...}`
- **THEN** 账号按空串处理，实例正常安装

#### Scenario: 端口越界

- **WHEN** `smtpPort: 70000`
- **THEN** 该条被跳过，错误信息指出端口超出范围

#### Scenario: 必填缺失

- **WHEN** email 条目缺 `smtpHost`
- **THEN** 该条被跳过并记录缺失字段

#### Scenario: starttls 未实现

- **WHEN** `tls: "starttls"`
- **THEN** 该条被跳过，错误说明暂只支持默认 SSL

#### Scenario: 配置读取失败

- **WHEN** 读取 `llm_channels` 时配置源抛异常
- **THEN** `installFromConfig` 返回带 error 的报告，不向外抛

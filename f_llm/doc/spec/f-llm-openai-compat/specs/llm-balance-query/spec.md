# Spec Delta

## Purpose

为「各家大模型平台的账户余额」提供统一查询契约与扩展点，使上层能用同一份快照字段消费不同平台的结果；本期只落接口与中介者，平台实现后置。

## ADDED Requirements

### Requirement: 统一余额快照

查询结果 SHALL 统一为包含平台、账号标识、币种、可用余额、现金、信用额度、冻结金额、总额、是否低于阈值、查询时间与原始响应的快照。

#### Scenario: 字段齐全
- **WHEN** 任一已实现的平台查询成功
- **THEN** 返回快照的平台、币种、查询时间非空，原始响应保留在该平台返回的 JSON 中

#### Scenario: 口径差异不做换算
- **WHEN** 平台返回的「总额」已包含信用额度
- **THEN** 快照原样保留该值与原始响应，不跨平台做统一换算

### Requirement: 实现分级

余额实现 SHALL 分两级：已实现平台返回真实数据；未实现平台 SHALL 存在一个可编译的占位实现，被调用时抛「不支持」异常，SHALL NOT 伪造数据。

#### Scenario: 已实现平台
- **WHEN** 查询 DeepSeek 余额且凭据有效
- **THEN** 返回真实余额快照，不含占位标记

#### Scenario: 占位实现被调用
- **WHEN** 查询一个只有占位的平台
- **THEN** 抛出「不支持」异常，消息说明该平台待实现

### Requirement: DeepSeek 余额映射

DeepSeek 余额查询 SHALL 使用 `GET /user/balance`，把每个币种条目映射为一条快照：总额取 `total_balance`、赠金取 `granted_balance`、充值余额取 `topped_up_balance`；金额是字符串，SHALL 按定点数解析。

#### Scenario: 单币种
- **WHEN** 响应为 `{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"110.00","granted_balance":"10.00","topped_up_balance":"100.00"}]}`
- **THEN** 快照币种为 `CNY`、可用余额 110.00、信用 10.00、现金 100.00，且未标记低余额

#### Scenario: 多币种
- **WHEN** `balance_infos` 同时含 CNY 与 USD 两条
- **THEN** 每个币种各产出一条快照，不取下标 0 覆盖

#### Scenario: 账户不可用
- **WHEN** 响应 `is_available = false`
- **THEN** 快照标记为低余额/不可用，并记录告警日志

### Requirement: 不支持的平台显式失败

未实现或无法查询的平台 SHALL 抛出明确的「不支持」异常，SHALL NOT 返回 0 或空快照。

#### Scenario: 未实现平台
- **WHEN** 查询一个没有实现的平台
- **THEN** 抛出「不支持」异常，异常消息包含平台标识

#### Scenario: 凭据缺失
- **WHEN** 平台已实现但配置中缺少所需凭据
- **THEN** 抛出「凭据缺失」异常，消息指出缺少的配置键

### Requirement: 可扩展的查询实现

新增平台 SHALL 只需提供一个声明平台标识的查询实现（自动发现或显式注册），不需要改框架代码；同一平台重复注册 SHALL 失败。

#### Scenario: 自动发现
- **WHEN** 新增一个带平台标识的查询实现并被容器发现
- **THEN** 无需改代码即可通过中介者查询该平台

#### Scenario: 重复注册
- **WHEN** 两个实现声明同一平台标识
- **THEN** 注册阶段失败，不进入服务状态

### Requirement: 低余额只告警不通知

余额低于阈值时系统 SHALL 只在快照上标记并记录一条告警日志，SHALL NOT 主动发送消息或邮件。

#### Scenario: 低于阈值
- **WHEN** 可用余额低于阈值
- **THEN** 快照的低余额标记为真，并产生一条告警日志；不产生任何外部通知

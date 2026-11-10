# Spec Delta

## Purpose

约束上下文压缩/裁剪的**对外语义**：策略如何命名、每个既有策略产出什么、饱和判断依据什么、调用方何时该裁；实现可以重写，也可以新增算法，但不能改变这些可观测行为。

## ADDED Requirements

### Requirement: 既有裁剪策略语义保持不变

系统 SHALL 保持以下 8 个策略的名字拼装规则与输出语义：`Retain`、`LastN_{n}`、`Summary_BY_{llmType}_{model}`、`Keywords_BY_{llmType}_{model}`、`DRC_{system}_{others}`、`Saturation_{pruner}`、`RetainLastUser_{pruner}`、`RetainLastNRound_{pruner}`。

#### Scenario: 保留全部
- **WHEN** 使用 `Retain` 策略
- **THEN** 输出的消息列表与输入逐条相同（数量与顺序都不变）

#### Scenario: 保留最近 N 轮
- **WHEN** 使用 `LastN_2`，输入含 6 条非 system 消息
- **THEN** 输出保留最后 4 条，且包含最后一条用户消息

#### Scenario: 摘要策略产出一条用户消息
- **WHEN** 使用 `Summary_BY_text_glm-5`
- **THEN** 输出至少一条 `role = user` 的总结消息，且策略名的两段来源与配置一致

#### Scenario: DRC 的前后顺序
- **WHEN** 使用 `DRC` 且 system 与其他消息分别配置了不同策略
- **THEN** system 消息的裁剪结果排在其它消息之前

### Requirement: 饱和判断按平台配置

饱和裁剪 SHALL 只在该平台配置的阈值被超过时触发；阈值为 0 表示该平台不限制，不触发裁剪。

#### Scenario: 未超过阈值
- **WHEN** 阈值为 80000、当前上下文估算为 30000
- **THEN** 不执行内层裁剪策略，原样返回

#### Scenario: 阈值为零
- **WHEN** 阈值为 0
- **THEN** 无论上下文多长都不触发裁剪

### Requirement: 裁剪不进入单次调用

单次模型调用 SHALL NOT 自动执行上下文裁剪；裁剪由会话编排显式调用。

#### Scenario: 直接调用门面
- **WHEN** 调用方直接发起一次非流式请求，且历史消息远超阈值
- **THEN** 发送的消息与传入的一致，不发生隐式裁剪

### Requirement: 可新增裁剪算法

新增裁剪算法 SHALL 只需实现策略接口并声明唯一名称，无需改框架代码；名称冲突 SHALL 在注册阶段失败。

#### Scenario: 新增策略可用
- **WHEN** 注册一个名为 `TokenBudget_4000` 的新策略
- **THEN** 按名称即可调用，且与既有策略共存

#### Scenario: 名称冲突
- **WHEN** 两个策略声明同一个名称
- **THEN** 注册阶段失败，不进入服务状态

### Requirement: 缺失策略显式失败

按名称调用未注册的策略 SHALL 立即失败，异常消息包含该名称与可用策略名列表。

#### Scenario: 未知策略名
- **WHEN** 调用 `prune(name: "NoSuchPruner")`
- **THEN** 抛出异常，且不发生任何消息裁剪

# Spec Delta

## ADDED Requirements

### Requirement: 陈旧路由必须摘除

`dispatch` 在派发前二次校验流程状态，若已不是 `compiled`，MUST 先把该流程从路由表摘除再返回「无可用流程」，MUST NOT 让它继续留在候选里。

#### Scenario: 流程被改回 pending

- **WHEN** 路由表里有 `daily`（compiled），但派发前流程库里的状态已变成 `pending`
- **THEN** 返回 `noUsableFlow`，且 `routes()` 不再包含 `daily`

### Requirement: 选路阶段不向外抛异常

`routable()` 与状态查询属于选路阶段，MUST 在异常保护内；存储不可用等异常 MUST 按「无可用流程」处理并返回结果对象，MUST NOT 抛给调用方。

#### Scenario: 路由表读取抛异常

- **WHEN** 读取路由表或查询流程状态时底层存储抛异常
- **THEN** `dispatch` 返回 `noUsableFlow`，不抛异常

### Requirement: 装配失败可观测

`LoomWiring.wire` MUST 保留启动恢复结果并可通过 `LoomWiring.lastReload()` 读取；`restoreFailed` 为真时 MUST 输出 warn 日志；`ReloadResult` 的文本表示 MUST 包含该字段。

#### Scenario: 库晚于应用就绪

- **WHEN** 流程存储不可用导致恢复失败
- **THEN** 装配继续完成，`lastReload().restoreFailed` 为真，并有一条 warn 日志

### Requirement: 装配不覆盖已安装宿主

`LoomWiring.wire` MUST 接受可选宿主参数；调用方已安装宿主时 MUST 沿用，MUST NOT 用默认宿主覆盖。优先级为「传入的 host」>「已安装 host」>「`DefaultLoomHost(chat)`」。

#### Scenario: 先装宿主后装配

- **WHEN** 调用方先 `LoomServices.installHost(自定义)`，再执行 `LoomWiring.wire`
- **THEN** `currentHost()` 仍是自定义宿主，Supervisor 也绑在它上面

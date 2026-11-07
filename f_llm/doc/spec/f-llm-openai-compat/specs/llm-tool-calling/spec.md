# Spec Delta

## Purpose

让模型在一次会话里调用外部能力：工具来自业务注册、框架内置与 MCP 三类来源，统一成同一份工具定义与同一个调用入口；内置当前时间、联网搜索与网页抓取三个函数。

## ADDED Requirements

### Requirement: 工具定义与调用

系统 SHALL 把三类来源（业务注册、内置、MCP）的工具统一成 `{name, description, parameters}` 定义交给模型，并能在模型返回工具调用时按名字执行、把结果作为工具消息回填。

#### Scenario: 业务工具可直接使用
- **WHEN** 某业务类以约定方式注册了函数 `readFile`
- **THEN** 工具定义里出现 `readFile`，模型调用后返回该函数的执行结果文本

#### Scenario: 未知工具名
- **WHEN** 模型返回了未注册的工具名
- **THEN** 该次调用失败并给出未找到的工具名，不静默忽略

### Requirement: 内置当前时间函数

系统 SHALL 提供内置函数 `currentTime`，返回本机当前时间，并支持可选时区与输出格式；不支持时区名时返回错误文本而非抛异常。

#### Scenario: 默认格式
- **WHEN** 调用 `currentTime` 且不传时区与格式
- **THEN** 返回 ISO 8601 时间，包含偏移量，同时给出 epoch 毫秒

#### Scenario: 非法时区
- **WHEN** 传入不存在的时区名
- **THEN** 返回说明该时区不可用的文本，函数不抛异常

### Requirement: 内置联网搜索函数

系统 SHALL 提供内置函数 `webSearch`：支持查询词、条数、指定平台与是否取正文；搜索能力由可注册的提供方声明，凭据取自任意启用的模型配置。

#### Scenario: 借已有配置的凭据
- **WHEN** 已启用配置里存在某个支持搜索的平台，且调用未指定平台
- **THEN** 搜索使用该平台的地址与凭据成功返回结果列表

#### Scenario: 无可用配置
- **WHEN** 所有启用配置都不支持搜索
- **THEN** 调用抛出「搜索不可用」异常，异常消息包含是否需要抓取能力与已注册的平台列表

#### Scenario: 指定平台无配置
- **WHEN** 指定 `provider = deepseek`，但没有任何启用配置属于该平台
- **THEN** 抛出异常，且不跨平台回退

#### Scenario: 结果归一
- **WHEN** 上游返回平台私有字段
- **THEN** 回给模型的结果统一包含标题、链接、摘要、发布时间与相关度，且总长度不超过工具结果上限

### Requirement: 内置网页抓取函数

系统 SHALL 提供内置函数 `webFetch`，抓取单个网页并返回 Markdown 正文；该函数 SHALL 实施服务端请求伪造（SSRF）防护。

#### Scenario: 公网地址
- **WHEN** 抓取一个公网 HTTP 地址
- **THEN** 返回标题与正文，正文超上限时截断并标注

#### Scenario: 内网地址被拒绝
- **WHEN** 抓取 `127.0.0.1`、`10.x`、`192.168.x`、`169.254.169.254` 或 `::1`
- **THEN** 调用失败，异常说明地址被拒绝

#### Scenario: 非 HTTP 协议
- **WHEN** 传入 `file:///etc/passwd`
- **THEN** 调用失败，不发起任何请求

#### Scenario: 跳转到内网
- **WHEN** 公网地址返回 302 指向内网地址
- **THEN** 不跟随该跳转并失败

### Requirement: MCP 工具来源

系统 SHALL 支持从 MCP server（HTTP 与 stdio 两种传输）加载工具，把其输入模式清洗成模型可接受的参数模式，并在模型调用时转发到对应 server。

#### Scenario: 加载并调用
- **WHEN** 一台 MCP server 暴露工具 `search_docs`
- **THEN** 工具表中出现带别名前缀的工具，调用后返回该 server 的文本结果

#### Scenario: 输入模式含不支持字段
- **WHEN** MCP 工具的模式含 `$schema`、`$ref` 或联合类型
- **THEN** 清洗后只保留 `type` / `properties` / `required` / `additionalProperties`，联合类型取第一个非空类型

#### Scenario: 工具自身报错
- **WHEN** MCP 返回错误结果
- **THEN** 错误文本作为工具结果回给模型，不中断本轮

### Requirement: 工具命名与冲突

工具名 SHALL 满足模型侧命名约束；MCP 工具名 SHALL 由别名与原名拼接且不得截断；任何重名 SHALL 在构建工具表时失败。

#### Scenario: MCP 工具名过长
- **WHEN** 拼接后的工具名超过 64 字符
- **THEN** 构建工具表失败，消息包含实际长度与「请缩短别名」

#### Scenario: 跨来源重名
- **WHEN** 业务工具与内置工具同名
- **THEN** 构建工具表失败，消息包含两个来源

#### Scenario: 别名重复
- **WHEN** 两台 MCP server 配置了相同别名
- **THEN** 构建工具表失败

### Requirement: 自动工具循环

系统 SHALL 提供可选的自动工具循环：模型返回工具调用时自动执行并回填，最多执行配置的轮数；默认关闭。

#### Scenario: 默认关闭
- **WHEN** 调用方未显式开启自动循环
- **THEN** 一次请求只调用一次模型，工具调用原样返回给调用方

#### Scenario: 轮数上限
- **WHEN** 开启自动循环且模型连续 9 轮都返回工具调用，上限为 8
- **THEN** 在第 8 轮后停止，返回结果标记轮数超限

# Spec Delta

## Purpose

把已编译的 loom 流程注册成可路由目标，让一段自然语言描述由模型判定落到哪条流程并触发执行，从而免去调用方自己记住「该调哪个流程」。

## ADDED Requirements

### Requirement: 功能开关与默认行为

Supervisor SHALL 由配置项 `llm_supervisor` 控制开关，默认关闭；关闭时系统 MUST 不注册流程、不进行流程选路，也不产生任何额外的模型调用。

#### Scenario: 默认关闭

- **WHEN** 进程启动且未设置 `llm_supervisor`（或设为 false）
- **THEN** 不创建 Supervisor 路由表，任何派发请求都不触发模型调用

#### Scenario: 显式开启

- **WHEN** 启动时设置 `llm_supervisor=true`
- **THEN** Supervisor 就绪，后续编译成功的流程会被自动登记

### Requirement: 流程注册与唯一事件名

开启后系统 SHALL 把每个流程登记为一条路由，包含流程名、描述与该流程在 Supervisor 内唯一对应的事件名；同一流程重复登记 MUST 幂等（不产生第二条路由），运行期 MUST 支持新增与删除路由。

#### Scenario: 登记两条流程

- **WHEN** 连续登记流程 `daily` 与 `weekly`
- **THEN** 路由表包含两条记录，且两者的事件名互不相同、均可由流程名唯一确定

#### Scenario: 重复登记同名流程

- **WHEN** 对同一流程名连续登记两次
- **THEN** 路由表仍只有一条该流程记录

#### Scenario: 运行期删除

- **WHEN** 删除已登记的流程 `weekly`
- **THEN** 路由表中不再包含 `weekly`，后续派发不会再选中它

### Requirement: 启动时从存储初始化

进程启动且功能开启时，系统 SHALL 从流程存储载入全部已存流程完成 Supervisor 初始化；载入单个流程失败或存储不可用 MUST NOT 阻断 loom 其它能力。

#### Scenario: 重启后路由可查

- **WHEN** 存储中已有 3 条流程，进程重启并开启 Supervisor
- **THEN** 启动后路由表包含这 3 条流程

#### Scenario: 存储不可用

- **WHEN** 流程存储读取失败
- **THEN** 启动继续，路由表为空或部分填充，不影响其它 loom 能力使用

### Requirement: 模型选路

系统 SHALL 接收一段描述文本，并把它连同每条可执行流程的名称、描述与事件名一起发给模型，由模型判定应交给哪个流程；判定 MUST 只考虑可执行状态的流程，模型输出无法解析、流程名为空或不在路由表内时 MUST 视为无可用流程，而不是抛错。

#### Scenario: 命中已有流程

- **WHEN** 描述文本匹配已登记且可执行的流程 `daily`
- **THEN** 模型收到的提示词包含各流程的名称、描述与事件名，返回结果指定 `daily`

#### Scenario: 模型输出非 JSON

- **WHEN** 模型返回的不是可解析的 JSON 对象
- **THEN** 按无可用流程处理，不抛异常

#### Scenario: 模型指向不可执行流程

- **WHEN** 模型返回的流程名存在但处于未编译状态
- **THEN** 按无可用流程处理，不执行该流程

### Requirement: 派发与执行

命中流程后，系统 SHALL 以该流程对应的 Supervisor 事件名构造起始事件、把原始描述作为事件数据投递，并执行该流程；返回结果 MUST 指明所用流程、事件名与执行产出。

#### Scenario: 派发到流程

- **WHEN** 选路结果为流程 `daily`
- **THEN** 流程以事件名为 `daily` 对应事件的起始事件被执行，事件数据等于原始描述，返回值包含流程名与执行产出

### Requirement: 无可用流程时直接返回

当判定没有可用流程且 `llm_loomOnNoUsable=false` 时，系统 MUST 立即返回「没有可完成此工作的流程」，且 MUST NOT 创建新流程或执行任何流程。

#### Scenario: 无匹配流程

- **WHEN** 模型判定无可用流程且 `llm_loomOnNoUsable=false`
- **THEN** 返回不含流程名的结果，消息为「没有可完成此工作的流程」，流程存储不新增记录

### Requirement: 无可用流程时自动新建

当判定没有可用流程且 `llm_loomOnNoUsable=true` 时，系统 SHALL 自动编排一条新流程（名称由框架生成且不与既有流程冲突）、登记到 Supervisor 并派发执行；编排结果为需要澄清时 MUST 返回澄清状态且不执行；该配置项仅在 `llm_supervisor=true` 时生效。

#### Scenario: 自动新建并执行

- **WHEN** 无可用流程且 `llm_loomOnNoUsable=true`，编排产生可编译流程
- **THEN** 新流程被登记并立即执行，返回结果标注为新建流程且包含其执行产出

#### Scenario: 新流程名冲突

- **WHEN** 框架生成的名称与既有流程重名
- **THEN** 系统改用不冲突的名称，不覆盖既有流程

#### Scenario: 编排需要澄清

- **WHEN** 自动编排返回需要澄清的问题
- **THEN** 返回澄清状态与问题列表，不执行流程，路由表不新增该流程

#### Scenario: 开关关闭时忽略

- **WHEN** `llm_loomOnNoUsable=true` 但 `llm_supervisor=false`
- **THEN** 行为与功能关闭一致，不新建流程

### Requirement: 流程生命周期联动

功能开启时，流程编译成功 MUST 自动登记、删除流程 MUST 自动摘除；功能关闭时这些联动 MUST 是无操作，不改变既有流程行为。

#### Scenario: 编译后自动登记

- **WHEN** 一条 pending 流程确认编译成功
- **THEN** 该流程出现在 Supervisor 路由表中，可被后续派发选中

#### Scenario: 删除流程后摘除

- **WHEN** 删除一条已编译流程
- **THEN** 路由表中同步移除该流程

#### Scenario: 功能关闭时无副作用

- **WHEN** `llm_supervisor=false` 时执行编译与删除
- **THEN** 不创建路由表，流程行为与未引入该功能前一致

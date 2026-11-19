# Spec Delta

## ADDED Requirements

### Requirement: 工具层具备完整读能力

系统 MUST 提供工具 `loomStoreCall`，其 `(kind, op, payload)` 语义与 `loomStore(...)` 完全一致，
覆盖 `memory`、`experience`、`knowledge`、`skill`、`prompt`、`character`，使 `kind=tool` 的步骤
可以直接读知识、读经验、加载技能，MUST NOT 要求把逻辑写进 JIT 片段。

#### Scenario: 工具读知识

- **WHEN** 工具循环调用 `loomStoreCall(kind="knowledge", op="search", payload={"text":"…","limit":5})`
- **THEN** 返回与 `loomStore("knowledge","search",…)` 相同的命中结果

#### Scenario: 工具加载技能

- **WHEN** 调用 `loomStoreCall(kind="skill", op="load", payload={"title":"日报助手"})`
- **THEN** 返回带正文的技能 JSON

#### Scenario: 缺参数

- **WHEN** `kind` 或 `op` 为空
- **THEN** 返回可读错误（如 `loomStoreCall requires kind`），不抛异常

#### Scenario: payload 不是对象

- **WHEN** `payload="oops"`
- **THEN** 返回 `payload must be a JSON object` 提示，不进入网关

### Requirement: 计划声明的技能在生产链路生效

`FlowPlan` MUST 支持 `skills`；`Planner` MUST 从计划 JSON 读入，缺省时回落 `LoomRequest.skills`；
`LoomService.executeNow` MUST 将其传给 `LoomRunner.run(skills:)`，并允许调用方显式覆盖。

#### Scenario: 计划里写了技能

- **WHEN** 计划 `skills=["日报助手"]` 且该技能在库中
- **THEN** `executeNow` 执行时 system 注入该技能正文

#### Scenario: 调用方覆盖

- **WHEN** `executeNow(..., skills: ["代码评审"])` 且计划里也写了别的技能
- **THEN** 以调用方给的为准

#### Scenario: 都没写

- **WHEN** 计划与请求都没有 `skills`
- **THEN** 行为不变：按任务描述自动检索

# Spec Delta

## ADDED Requirements

### Requirement: 经验检索覆盖失败经验

`loomStore("experience", op, …)`（`op` 为 `search` 或 `list`）MUST 同时覆盖 `experience` 与 `experience_failed` 两种 kind；调用方显式给出 `kind` 时 MUST 以显式值为准。

#### Scenario: 默认同时召回两类经验

- **WHEN** 同一用户下分别有一条 `experience` 与一条 `experience_failed`，且检索不指定 kind
- **THEN** 两条都出现在结果里

#### Scenario: 显式 kind 优先

- **WHEN** 调用方传 `kind:"experience"`
- **THEN** 只返回 `experience`，不返回 `experience_failed`

### Requirement: 分页参数的确定缺省

`memory.list` 与 `knowledge.docIds` 在缺少 `limit`、或 `limit<=0` 时 MUST 使用缺省上限 50，MUST NOT 因参数缺失返回空数组；`offset` 缺省为 0。

#### Scenario: 不传 limit

- **WHEN** 已写入 3 条记忆，调用 `memory.list` 只传 userId 与 namespace
- **THEN** 返回这 3 条，而不是空数组

#### Scenario: limit 为 0

- **WHEN** 调用方传 `limit:0`
- **THEN** 按缺省 50 处理

### Requirement: jit 步骤拒绝模板占位符

`kind=jit` 的步骤源码若包含 `{…}` 形式的模板占位符，编译期 MUST 抛错并说明替代写法，MUST NOT 把它当普通代码继续编译。

#### Scenario: jit 里写 {start.output}

- **WHEN** 某 jit 步骤的 `input` 含 `{start.output}`
- **THEN** 编译失败，错误信息指出 jit 不支持模板替换并建议用 `llm`/`tool` 步骤或 `loomStore`

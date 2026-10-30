# llm-meta-store Specification

## Purpose
为人格、技能、提示词与模型配置提供统一的元数据存取契约，并支持仅用 `f_store` 运行，使 f_llm 在没有 PostgreSQL/MySQL 的环境中也能完整启动。

## Requirements

### Requirement: 元数据后端由配置选择

系统 SHALL 读取 `llm_metaStore` 决定元数据族实现，合法值为 `postgres`、`mysql`、`f_store`；取值未知或未注册时 MUST 启动失败并列出可选值，不得静默回退。

#### Scenario: 合法配置装载对应实现
- **WHEN** `llm_metaStore=f_store`
- **THEN** `Stores.meta()` 返回 f_store 元数据族实例

#### Scenario: 未知配置拒绝启动
- **WHEN** `llm_metaStore=redis`
- **THEN** 启动失败，错误信息包含 `redis` 与 `postgres, mysql, f_store`

### Requirement: 仅用 f_store 运行

元数据族 SHALL 提供基于 `f_store` 的实现，使 f_llm 在未配置任何数据库时仍可读写人格、技能、提示词与模型配置；进程重启后 MUST 保留已写入的数据。

#### Scenario: 重启后数据仍在
- **WHEN** 以 `llm_metaStore=f_store` 写入人格与模型配置后重启进程
- **THEN** 读取到与重启前一致的人格与配置

#### Scenario: 主体与索引不一致时启动修复
- **WHEN** 上次写入在「写主体、写索引」之间崩溃
- **THEN** 下次启动扫描主体并补建缺失索引，读取正常

### Requirement: 人格存取

系统 SHALL 为每个用户保存至多一条人格记录，`character_key` 取 13 个预定义值之一或 `custom`；写入 `custom` 时 `prompts` MUST 原样保存；`reset` MUST 使该用户回落到 `default`。

#### Scenario: 一人一条覆盖写
- **WHEN** 同一用户先后设置 `rigorous` 与 `friendly`
- **THEN** 该用户只有一条人格记录，值为 `friendly`

#### Scenario: 未知 character_key 被拒绝
- **WHEN** 设置 `character_key=not-exist`
- **THEN** 返回参数错误，原人格保持不变

#### Scenario: reset 回到默认
- **WHEN** 对已设置自定义人格的用户调用 `reset`
- **THEN** 读取结果为 `default`，不再注入 system 提示词

### Requirement: 模型配置候选

元数据族 SHALL 提供模型配置查询：按 `llmName` 返回候选列表，且 MUST 过滤 `enabled=false` 与 `weight<=0` 的记录；结果 MUST 与现有 `LLMConfs` 快照的候选语义一致。

#### Scenario: 零权重配置不进入候选
- **WHEN** 某 `llmName` 下只有一条 `weight=0` 的配置
- **THEN** 候选列表为空

#### Scenario: 禁用配置不进入候选
- **WHEN** 配置 `enabled=false`
- **THEN** 该配置不出现在任何候选列表

### Requirement: 技能与提示词存取

元数据族 SHALL 提供技能与提示词的读写：技能记录包含 `version`（默认 1），提示词按 `(name, version)` 存取并保留最新版本指针；查询不存在的记录 MUST 返回空值而不是抛异常。

#### Scenario: 技能版本默认值
- **WHEN** 新建一条技能记录
- **THEN** 其 `version` 为 1

#### Scenario: 查询不存在的提示词
- **WHEN** 查询 `name=not-exist`
- **THEN** 返回空值，不抛异常

### Requirement: 元数据族实现可替换

系统 SHALL 提供 `Stores.registerMeta(name, factory)` 扩展点；注册后 MUST 能通过 `llm_metaStore` 选中。内存实现 MUST 仅用于测试，不得出现在可选值列表。

#### Scenario: 注册自定义实现后可被配置选中
- **WHEN** 注册 `name=custom-meta` 的元数据族实现并配置 `llm_metaStore=custom-meta`
- **THEN** `Stores.meta()` 返回该自定义实现

#### Scenario: 测试替身不作为可选值
- **WHEN** 检查 `llm_metaStore` 的合法值列表
- **THEN** 列表为 `postgres`、`mysql`、`f_store`，不含 `memory`

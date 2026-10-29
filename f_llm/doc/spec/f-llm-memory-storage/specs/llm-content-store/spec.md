# Spec Delta

## Purpose

为记忆、经验、知识与文档提供统一的内容存取契约，使 f_llm 可以在 PostgreSQL、MySQL 与 fhydra 之间按配置切换，且调用方不感知具体后端。

## ADDED Requirements

### Requirement: 内容后端由配置选择

系统 SHALL 读取 `llm_contentStore` 决定内容族实现，合法值为 `postgres`、`mysql`、`fhydra`；取值未知或未注册时 MUST 启动失败并列出可选值，不得静默回退到默认实现。

#### Scenario: 合法配置装载对应实现
- **WHEN** `llm_contentStore=postgres` 且该实现已注册
- **THEN** `Stores.content()` 返回 PostgreSQL 内容族实例

#### Scenario: 未知配置拒绝启动
- **WHEN** `llm_contentStore=sqlite`
- **THEN** 启动失败，错误信息包含 `sqlite` 与 `postgres, mysql, fhydra`

### Requirement: 记忆按用户与命名空间隔离

系统 SHALL 以 `(user_id, namespace)` 作为记忆的隔离边界；`namespace` 取 `global` 或 `ws-{workspaceId}`。任何查询 MUST 限定单个用户，且 MUST NOT 返回其他用户或其他工作空间的记忆。

#### Scenario: 跨用户不可见
- **WHEN** 用户 A 检索记忆
- **THEN** 结果中不含用户 B 的任何记忆

#### Scenario: 全局记忆跨工作空间可见
- **WHEN** 用户 A 在 `ws-1` 中检索且存在 `namespace=global` 的记忆
- **THEN** 该全局记忆出现在结果中

### Requirement: 记忆种类注册表

系统 SHALL 维护记忆种类：预定义 7 个（`note`、`fact`、`preference`、`task`、`doc`、`knowledge`、`session`），自定义种类归属到创建它的用户。预定义种类 MUST NOT 被删除；删除 MUST 抛出 `IllegalArgumentException`。启动时 SHALL 幂等补种预定义行。

#### Scenario: 删除预定义种类被拒绝
- **WHEN** 调用 `MemoryKinds.remove(uid, "note")`
- **THEN** 抛出 `IllegalArgumentException`，且 `note` 仍然可用

#### Scenario: 自定义种类仅本用户可见
- **WHEN** 用户 A 注册 `meeting`，用户 B 查询种类列表
- **THEN** 用户 B 的列表包含 7 个预定义种类、不包含 `meeting`

#### Scenario: 未知种类写入被拒绝
- **WHEN** 写入 `kind=unknown-kind` 的记忆
- **THEN** 返回参数错误，且不产生任何记录

### Requirement: 记忆写入与幂等覆盖

系统 SHALL 对标题与正文分别生成向量；同一 `(user_id, namespace, title)` 的重复写入 MUST 覆盖原记录而不是新增。向量化失败时 MUST 拒绝写入并返回错误，不得保存无向量记忆。

#### Scenario: 同标题重复写入覆盖
- **WHEN** 同一用户在同一命名空间两次写入标题相同的记忆
- **THEN** 该标题只有一条记录，内容为第二次写入的值

#### Scenario: 向量服务不可用时拒绝写入
- **WHEN** BGE-M3 服务不可达时写入记忆
- **THEN** 返回错误，且不产生新记录

### Requirement: 记忆检索与权重排序

系统 SHALL 按相似度返回 `id`、`title`、`content` 与 `score`；评分 MUST 乘以该记忆 `kind` 的固定权重（`session=0.3`、`task=0.6`、`doc/knowledge=0.8`、`note=0.9`、`fact/preference=1.0`），并在乘以权重前先取 `topK × 2` 候选。返回数量 MUST 不超过 `topK`。

#### Scenario: 高权重记忆优先
- **WHEN** 两条记忆相似度相同，`kind` 分别为 `fact` 与 `session`
- **THEN** `fact` 的 `score` 高于 `session`，排序在前

#### Scenario: 返回数量受 topK 限制
- **WHEN** 命中 50 条且 `topK=5`
- **THEN** 只返回 5 条

### Requirement: 稀疏向量参与召回

系统 SHALL 把标题与正文的稀疏权重按 token 落入倒排表，并在检索时按命中 token 累加权重；融合权重 MUST 默认为 dense 0.7 / sparse 0.3。写入方未提供稀疏向量时，系统 SHALL 降级为 dense-only 并在结果中标记。

#### Scenario: 词面命中通过稀疏通路召回
- **WHEN** 查询包含与某记忆正文相同的专有名词
- **THEN** 该记忆进入候选集，且 `components.sparse` 大于 0

#### Scenario: 无稀疏向量时降级
- **WHEN** 记忆只有 dense 向量、没有 sparse
- **THEN** 检索仍返回结果，响应标记 `degraded=true`

### Requirement: 多头向量重排

系统 SHALL 在候选集上使用标题与正文的 colbert 向量做 max-sim 重排；`rerank=false` 时 MUST NOT 计算 colbert 相似度。重排 MUST 只改变排序，不改变候选集。

#### Scenario: 开启重排改变排序
- **WHEN** 同一查询分别以 `rerank=false` 与 `rerank=true` 执行
- **THEN** 两次返回的 id 集合相同，排序可能不同

#### Scenario: 关闭重排不读取 colbert
- **WHEN** `rerank=false`
- **THEN** 不查询 `title_colbert` / `content_colbert` 列

### Requirement: MySQL 与 PostgreSQL 行为一致

系统 SHALL 让 `PostgresContentStore` 与 `MySqlContentStore` 通过同一套 conformance 用例；MySQL 版本低于 9.2（无可用向量索引）时 MUST 降级为应用层暴力计算并记录 `warn`，不得拒绝启动。

#### Scenario: 两后端返回一致结果
- **WHEN** 同一数据集分别写入 PG 与 MySQL 并执行同一查询
- **THEN** 两个后端的 topK id 集合一致（分数允许浮点误差）

#### Scenario: 无向量索引时降级
- **WHEN** MySQL 9.0/9.1 没有可用 `VECTOR INDEX`
- **THEN** 检索仍返回结果，日志含降级 `warn`

### Requirement: 内容族实现可替换

系统 SHALL 提供 `Stores.registerContent(name, factory)` 扩展点；开发者注册实现后 MUST 能通过 `llm_contentStore` 选中。内存实现 MUST 仅用于测试，不得出现在可选值列表。

#### Scenario: 注册自定义实现后可被配置选中
- **WHEN** 注册 `name=custom` 的内容族实现并配置 `llm_contentStore=custom`
- **THEN** `Stores.content()` 返回该自定义实现

#### Scenario: 测试替身不作为可选值
- **WHEN** 检查 `llm_contentStore` 的合法值列表
- **THEN** 列表为 `postgres`、`mysql`、`fhydra`，不含 `memory`

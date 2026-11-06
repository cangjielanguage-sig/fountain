# 已知限制

> 只记录**当前实现**下无法在 f_llm 内部解决的限制，以及永久设计约束。
> 每条写清：现象、影响、当前做法、解除条件。功能缺口见 `doc/todo.md`。

## 0. 运行期修改配置：不支持（设计约束）

**现象**：所有配置只在进程启动时读取一次；换实现、换端点、改权重都必须重启。

**原因**：

1. `f_bean` 的条件装配在 `BeanFactory.instance.afterRegistered()` 时评估一次，被丢弃的 bean 不可恢复；
2. `StoreWiring.wire()` 幂等注册与种类补种也只做一次；
3. `LLMConfsHolder`、各存储实现都在首次使用时定死。

**影响**：配置热更新、配置中心推送、按请求切换后端都不在支持范围。运行期改 `llm_memoryStore` / `llm_metaStore` / `llm_embeddingUrl` 不生效。

**当前做法**：需要切换时重启；进程内的「多实现」通过中介者模式（按运行时参数选实现）解决，而不是改配置。

## 1. HTTP 建连超时无法设置

**现象**：`BgeM3Transport` 只能设置读/写超时（`llm_embeddingTimeoutMs`），不能设置建连超时。

**原因**：`fountain::f_httpclient` 只暴露 `readTimeout` / `writeTimeout`；其下层 `stdx.net.http` 的 `ClientBuilder` 没有 `connectTimeout` 入口。

**影响**：向量服务主机不可达（丢包、防火墙 DROP）时，建连阶段会等到操作系统 TCP 超时（Linux 默认约 130 秒），期间 `embed` 阻塞，`llm_embeddingRetries` 无法缓解（每次重试都要重等）。

**当前做法**：读/写超时已覆盖「服务可达但响应慢」；不可达场景依赖 OS 参数（`net.ipv4.tcp_syn_retries`）。

**解除条件**：`stdx.net.http` 提供 `connectTimeout`，或 `f_httpclient` 改为自行建连后交给 client。

## 2. BGE-M3 三路依赖专用服务

**现象**：`BgeM3Transport` 请求 `return_sparse` / `return_colbert_vecs`，只有 `deploy_bge_m3.sh` 部署的服务会返回 `lexical_weights` / `colbert_vecs`。

**影响**：把 `llm_embeddingUrl` 指向普通 OpenAI 兼容 `/embeddings`（只回 `embedding`）时，sparse 与 colbert 为空，检索结果标 `degraded=true`，重排失效。

**当前做法**：改用 `LlmEmbeddingTransport`（dense-only），并在调用方接受 `degraded` 标记。

**解除条件**：目标端点按 FlagEmbedding 的字段名返回稀疏/colbert，或继续用仓库内的部署脚本。

## 3. MySQL 需要 MyVector 才有向量索引

**现象**：MySQL Community 构建没有 `VECTOR INDEX` / `VECTOR_DISTANCE`；`VECTOR(1024)` 可建表但不能建索引。

**影响**：不装 MyVector 时 MySQL 内容族直接不可用（建表即失败，不是降级）。

**当前做法**：MyVector 组件 + `MYVECTOR(type=HNSW,...)` 列 + `MYVECTOR_IS_ANN` 查询。额外要求：

- binlog 账号需 `SELECT, LOCK TABLES, REPLICATION CLIENT, REPLICATION SLAVE`；
- 应用账号需 `EXECUTE ON mysql.*`；
- 隔离条件放 `MYVECTOR_IS_ANN` 的第五个参数，写 `WHERE` 是后置过滤；
- ANN 查询不能用预处理占位符，DAO 内用字面量拼接（向量只含数字，namespace 做引号转义）。

**解除条件**：MySQL Community 提供原生向量索引，或改用 PostgreSQL。

## 4. f_store 单实例语义、无事务

**现象**：同一目录被两个 `Store` 实例打开时彼此看不到对方的写入；「主体 + 索引」两阶段写没有事务。

**影响**：写入过程中崩溃会留下「有主体、缺索引」的状态；跨实例读不到新数据。

**当前做法**：`FStoreMetaStore` 全程只持有一个 `Store` 实例；启动时扫描主体补齐缺失索引；`PromptStore.remove` 删除后重算 `latest` 指针。

**解除条件**：`f_store` 支持文件锁 / WAL 或跨实例可见性。

## 5. 换 Embedder 后需手工重建向量

**现象**：sparse 倒排与 colbert 向量是写入时的附加产物。换了向量模型或某一路缺失时，这两路会过期。

**影响**：检索退化为 dense-only（结果标 `degraded`），重排无效。

**当前做法**：`MemoryIndexRebuilder` / `KnowledgeIndexRebuilder`：

```cj
// 直接调用
MemoryIndexRebuilder.rebuild(repo, embedder, userId, namespace, batchSize: 100)

// 配置驱动，启动后调用一次
MemoryIndexRebuilder.rebuildIfConfigured(repo, embedder)
// 需要 llm_rebuildIndexOnStart=true（可选 llm_rebuildIndexUserId / llm_rebuildIndexNamespace）
```

只重算 sparse / colbert，不动 dense；dense 因换模型而失效时用覆盖写重建。

**解除条件**：无（属于运维动作，按需执行）。

## 6. 内容族不产出 MemoryRepository bean

**现象**：`f_hydra` / `fhydra` 通过 `ContentStore` 提供记忆与知识能力，不注册 `MemoryRepository` bean。

**影响**：`lookupOption<MemoryRepository>()` 在 `llm_memoryStore=f_hydra|fhydra` 下拿不到 bean；需要该 bean 的场景要配 `postgres` / `mysql`。

**当前做法**：错误信息明确提示「内容族走 ContentStore，不注册 MemoryRepository bean」。

**不是缺陷**：`f_hydra` 是默认且受支持的路径，只是不产出该 bean。

## 7. 余额查询：zhipu / siliconflow / aliyun 未实现

**现象**：三个类已注册、provider 名可路由，但 `query()` 直接抛 `BalanceUnsupportedException`。

**影响**：调用这三家的余额接口得到明确异常（不静默返回 0）；余额聚合与阈值告警对这三家不可用。不影响对话、记忆、检索主链路。

**实现要点**（照抄已实现的 provider 模式）：

- 参考 `DeepSeekBalanceQuerier`（`GET /user/balance`，`conf.auth` 作 Bearer）；
- 需要签名的参考 `TencentCloudBalanceQuerier` / `VolcengineBalanceQuerier`（`BalancePoster` 是注入点，可单测签名与解析）；
- 结果统一成 `ArrayList<BalanceSnapshot>`，金额保留原始字符串（`BalanceUnits.parse` 另给 `Float64` 视图）。

**解除条件**：三家接口形态确认后逐个补（每个约「一个类 + 一组解析用例」）。

## 8. 知识检索的残留限制

**已具备**：三后端语义召回（dense 分 + 词面加权）、词面候选分页、dense `topK` 随 `limit` 放大、`KnowledgeIndexRebuilder` 重建块向量。

| 限制 | 说明 |
|---|---|
| 词面权重不可配 | 加权系数是常量（`0.1`），不同语料没有调参入口 |
| MySQL 需组件 + 建索引 | 必须有 MyVector，写入后要 `CALL myvector_index_build('db.llm_document_chunk.content_vec','id')`；忘记建索引时 ANN 召回不可用 |
| 词面只取首词 | `LIKE '%<首个词>%'` 仅用于补候选；首词不出现时该记录只能靠向量召回 |
| 重建需手工触发 | `KnowledgeIndexRebuilder` 没有启动任务/定时任务，换 Embedder 后要自己调用 |
| 候选有总量上限 | 超大库里可能漏召回；没有二次精排或分层召回 |

**解除条件**：权重配置化；MySQL 建索引纳入启动检查；多词 OR 召回；重建做成运维任务；粗排 → 精排。

## 9. 附件落盘只做进程内互斥

`AttachmentSink` 用进程内 `Mutex` 串行化「选名 + 创建」，同一进程的多路收信不会互相覆盖。
两个进程同时往一个下载目录落同名附件时仍可能覆盖——需要文件锁，`std.fs` 目前没有稳定 API。单进程部署下可忽略。

## 10. 邮件通道的 TLS 只有默认行为

`FEmailTransport` 用 `f_email` 的默认 SSL 直连，没有 starttls 入口。装配时 `tls` 只接受空串或 `ssl`，其它取值（含 `starttls`）会被跳过并记录错误——不做静默忽略。


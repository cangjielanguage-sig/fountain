# 已知限制与待办

本文件记录**当前无法在 f_llm 内部解决**、需要外部条件（标准库、服务器构建、第三方组件）的限制，
以及少数**永久设计约束**（§0）。每条都写明现象、影响、现在的替代做法，以及解除条件——避免后来者误判为 bug 或遗漏。

最后更新：2026-10-31

---

## 0. 运行期修改配置：永久不支持（设计约束）

**结论**：f_llm **永远不会支持运行期修改配置**。所有配置只在进程启动时读取一次；
要换实现、换端点、改权重，都必须**重启进程**。

**为什么**：

1. `f_bean` 的条件装配（`@BeanMeta[condition: ConfCond.Value(...)]`）在
   `BeanFactory.instance.afterRegistered()` 时评估**一次**，被丢弃的 bean 不可恢复；
2. `StoreWiring.wire()` 幂等注册内容族/元数据族与种类补种，也只做一次；
3. `LLMConfsHolder`、`SqlMemoryStore` 的仓库/向量化实现都在首次使用时定死。

**影响（有意为之，不是缺陷）**：

- 配置热更新、配置中心推送、按请求切换后端都**不在支持范围**；
- 运行期改 `llm_memoryStore` / `llm_metaStore` / `llm_embeddingUrl` 后，行为仍按启动时的值，
  直到重启；
- 测试里不能「改配置 → 断言实现类型」，因为容器已经按旧配置筛选完毕
  （这也是 `BeanCondition_test` 把相关断言合并成单次配置的原因）。

**正确做法**：需要切换时，改配置 → 重启；进程内的「多实现」只能通过
**中介者模式**（按运行时参数选实现）解决，而不是改配置。

---

## 1. HTTP 连接级超时缺失（等 stdx 支持）

**现象**：`BgeM3Transport` 只能设置读/写超时（`llm_embeddingTimeoutMs`，默认 3000ms），
无法设置建连超时。

**原因**：`fountain::f_httpclient` 只封装了 `readTimeout` / `writeTimeout`；
其下层 `stdx.net.http` 的 `ClientBuilder` 没有 `connectTimeout` 入口。

```cangjie
// f_httpclient/src/httpclient.cj 现有的全部超时入口
public static func globalReadTimeout(readTimeout: Duration): Unit
public static func globalWriteTimeout(writeTimeout: Duration): Unit
public func readTimeout(timeout: Duration): This
public func writeTimeout(timeout: Duration): This
```

**影响**：向量服务所在主机**不可达**（丢包、防火墙 DROP）时，建连阶段会等到操作系统
TCP 超时（Linux 默认约 130 秒），期间 `embed` 调用会阻塞，`llm_embeddingRetries` 也帮不上忙
（每次重试都要重新等一遍）。

**当前替代**：读/写超时已设置，服务可达但响应慢的场景能正常中断；不可达场景依赖 OS 参数
（`net.ipv4.tcp_syn_retries`）。

**解除条件**：`stdx.net.http` 提供 `connectTimeout`，或 `f_httpclient` 改为自行
`StreamingSocket` 建连后再交给 client。届时在 `BgeM3Transport` 里补一行即可。

---

## 2. BGE-M3 三路依赖专用服务，OpenAI 兼容端点只有 dense

**现象**：`BgeM3Transport` 请求 `return_sparse` / `return_colbert_vecs`，只有
`deploy_bge_m3.sh` 部署的服务（`/opt/bge-m3`）会返回 `lexical_weights` / `colbert_vecs`。

**影响**：把 `llm_embeddingUrl` 指向普通 OpenAI 兼容 `/embeddings`（只回 `embedding`）时，
sparse 与 colbert 为空，检索结果标 `degraded=true`，`rerank` 失效（重排分恒为 0）。

**当前替代**：改用 `LlmEmbeddingTransport`（复用既有 `Embedding` 客户端，dense-only），
并在调用方接受 `degraded`。

**解除条件**：目标端点按 FlagEmbedding 的字段名返回稀疏/colbert，或继续用本仓库的部署脚本。

---

## 3. MySQL Community 没有原生向量索引，必须装 MyVector

**现象**：MySQL 8.x / 9.7 / 26.10 的 Community 构建都没有 `VECTOR INDEX`、`VECTOR_DISTANCE`；
`VECTOR(1024)` 类型可建表但不能建索引。

**影响**：不装 [MyVector](https://github.com/askdba/myvector) 时，MySQL 内容族**直接不可用**
（不是降级：`MYVECTOR` 类型不存在，建表即失败）。

**当前替代**：MyVector 组件 + `MYVECTOR(type=HNSW,...)` 列 + `MYVECTOR_IS_ANN` 查询。
额外要求：

- binlog 账号需 `SELECT, LOCK TABLES, REPLICATION CLIENT, REPLICATION SLAVE`；
- 应用账号需 `EXECUTE ON mysql.*`（建索引/状态是存储过程）；
- 隔离条件必须放 `MYVECTOR_IS_ANN` 第五参数（`JSON_ARRAYAGG` 子查询），写 `WHERE` 是后置过滤；
- ANN 查询不能走预处理占位符，DAO 内用字面量拼接（向量只含数字，namespace 做引号转义）。

**解除条件**：MySQL 官方在 Community 版提供向量索引，或改用 PostgreSQL（pgvector）。

---

## 4. `f_store` 单实例语义、无事务

**现象**：同一目录被两个 `Store` 实例打开时，彼此看不到对方的写入；「主体 + 索引」两阶段写
没有事务。

**影响**：

- 测试里另开实例删索引再读，读不到变化（需同一个实例内操作）；
- 写入过程中崩溃会留下「有主体、缺索引」的状态。

**当前替代**：`FStoreMetaStore` 全程只持有一个 `Store` 实例；`FLLMConfStore.repair()` 在启动时
扫描主体、补齐缺失索引；`PromptStore.remove` 删除后重算 `latest` 指针。

**解除条件**：`f_store` 支持文件锁/WAL 或跨实例可见性。

---

## 5. 历史数据需要显式重建 sparse / colbert

**现象**：sparse 倒排与 colbert 向量是写入时的附加产物。早期数据只写了 dense，
或换过向量模型，这两路会缺失/过期。

**影响**：检索退化为 dense-only（结果标 `degraded`），`rerank` 无效。

**当前替代**：`MemoryIndexRebuilder`

```cj
// 直接调用
MemoryIndexRebuilder.rebuild(repo, embedder, userId, namespace, batchSize: 100)

// 配置驱动，启动后调用一次
Config.set<Bool>([('llm_rebuildIndexOnStart', true)])
Config.set<Int64>([('llm_rebuildIndexUserId', 0)])
Config.set<String>([('llm_rebuildIndexNamespace', 'global')])
MemoryIndexRebuilder.rebuildIfConfigured(repo, embedder)
```

只重算 sparse / colbert，不动 dense；换模型导致 dense 失效时用 `MemoryStore.add` 覆盖写。

**解除条件**：无（属于数据迁移，按需执行）。

---

## 6. fhydra 内容族尚未实现

**现象**：`MemoryStoreAdapter` / 内容族注册表的默认实现按设计应指向 fhydra，
当前 `f_hydra` / `fhydra` 都没有可用实现。

**影响**：`llm_memoryStore` 配成 `f_store` / 未知值且没有 bean 匹配时，适配器**显式抛错**
（列出可用值），不会静默回退到 PG。

**当前替代**：`llm_memoryStore=postgres|mysql|inMemory`。

**解除条件**：fhydra 提供 `MemoryStore` 实现并注册为 bean。

---

## 7. 余额查询：zhipu / siliconflow / aliyun 仍为占位（内部待办，暂不实现）

**现状**：三个类已经 `@Bean` 注册、provider 名可被路由到，但 `query()` 直接抛异常：

```cangjie
// f_llm/src/balance/BalanceQueriers.cj:275
/** 智谱 / 硅基流动 / 阿里云：本期只留可编译占位，调用即抛「不支持」 */
public class ZhipuBalanceQuerier <: BalanceQuerier {
    public func query(conf: LLMConf): ArrayList<BalanceSnapshot> {
        throw BalanceUnsupportedException('balance query for zhipu is not implemented yet')
    }
}
// SiliconFlowBalanceQuerier → 'balance query for siliconflow is not implemented yet'
// AliyunBalanceQuerier    → 'balance query for aliyun is not implemented yet'
```

**影响**：调用这三家的余额接口会得到明确的 `BalanceUnsupportedException`（不静默返回 0）；
余额聚合、阈值告警对这三家不可用。不影响对话、记忆、检索等主链路。

**实现要点**（照抄已实现的 provider 模式即可）：

- 参考 `DeepSeekBalanceQuerier`（`GET /user/balance`，`conf.auth` 作为 Bearer）；
- 需要签名的参考 `TencentCloudBalanceQuerier` / `VolcengineBalanceQuerier`（`BalancePoster` 是注入点，可单测签名与解析）；
- 解析结果统一成 `ArrayList<BalanceSnapshot>`，金额保留原始字符串（`BalanceUnits.parse` 同时给 `Float64` 视图）。

**待确认（这也是暂不实现的原因）**：

| provider | 需要确认 |
|---|---|
| zhipu | 余额接口是否存在/是否仅控制台可见、鉴权是否沿用 `conf.auth` |
| siliconflow | 余额接口路径与响应字段（是否与 DeepSeek 同构） |
| aliyun | 阿里云是 AK/SK 签名（`AccessKeyId/Secret` 在 `conf.conf` 或 `auth` 里），不是简单 Bearer |

**优先级**：低。等接口形态确认后再按 provider 逐个补，每个约「一个类 + 一组解析用例」的量级。

---

## 8. 知识检索目前只有词面召回（语义检索待实现）

**现状**：`KnowledgeStore.search` 已可用（块级、多词命中数排序、可按 `docIds` 限定），
但召回是 `LIKE '%<首个词>%'` + 内存打分，**没有块向量、没有 ANN**。

**影响**：

- 近义/改写的提问召回不到（「怎么配置」匹配不到「如何设置」）；
- 长文档里首个词不出现、但其它词出现时，整条记录不进入候选（召回以第一个词为准）；
- 候选上限 200，超大库会漏召回。

**解除条件**：给 `llm_document_chunk` 加向量列（PG `vector(1024)` / MySQL `MYVECTOR`），
`upsert` 时对每块调用 `Embedder.embed`，`search` 改为 dense ANN + 词面混合打分。
索引重建复用 `MemoryIndexRebuilder` 的思路（按 doc 分页重算）。

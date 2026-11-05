# 未实现项

> 只列**当前没有实现**的能力，以及为什么暂不实现。限制类问题见 `doc/known-limitations.md`。

## 1. 占位实现

| 项 | 位置 | 现状 |
|---|---|---|
| 余额查询 zhipu / siliconflow / aliyun | `src/balance/BalanceQueriers.cj` | `query()` 抛 `BalanceUnsupportedException`；接口形态待确认，详见 `known-limitations.md` §7 |

## 2. 单一实现 / 降级路径

| 项 | 现状 |
|---|---|
| 联网搜索 provider | 只有 `DeepSeekSearchProvider`；Bing / Google / 百度等需外部凭据，未实现 |
| OpenAI 兼容端点的 sparse / colbert | `LlmEmbeddingTransport` 只有 dense，用它检索结果标 `degraded=true`；三路需 `BgeM3Transport` |
| `listByKind` 的 SQL 下推 | 接口默认实现是「取一页再过滤」；`postgres` / `mysql` 的内存仓储覆盖成精确版，但 SQL 条件尚未下推到仓储层 |
| 分级相关性标注 | 评测用二值相关（命中 / 未命中），没有「很相关 / 部分相关」的标注与 nDCG 分级增益 |

## 3. 外部 / 设计约束

| 项 | 说明 |
|---|---|
| 运行期修改配置 | 永久不支持，必须重启（`known-limitations.md` §0） |
| HTTP 建连超时 | `stdx.net.http` 无 `connectTimeout`（§1） |
| MySQL 向量索引 | 依赖 MyVector 组件 + 手工 `myvector_index_build`（§3） |
| f_store 单实例、无事务 | 组件语义，靠启动修补兜底（§4） |
| 换 Embedder 后重建 | 需显式调用重建工具（§5） |

## 4. 尚未设计的扩展

| 项 | 说明 |
|---|---|
| 跨进程编排互斥 | 编排与流程执行只在进程内串联；多副本下同一流程可能被多个进程同时执行。技能演进有每日租约，编排没有 |
| 演进重建的原子性 | 重建倒排中途崩溃会留下部分重建状态；下次启动按「配置已变」重扫，可自愈但没有进度记录 |
| `processedKnowledge` 的分页 | 全量读取受实现上限约束，目前只用于运维查看；去重已走 `processedAmong`，无上限 |

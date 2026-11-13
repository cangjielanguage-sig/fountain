# f_hydra

进程内向量存储（动态库）：`collection → record → 三路向量`，基于 `f_store` 落盘，**不依赖任何数据库**。

f_llm 的默认内容族（`llm_memoryStore=f_hydra`）就是它；远程部署时由 `fhydra` 把同一套能力暴露成 JSON-RPC。

## 构建与测试

```bash
cd f_hydra
cjpm build
cjpm test        # 37/37
```

## API

```cangjie
public interface VectorStore {
    func upsert(collection: String, record: VectorRecord): Unit
    func get(collection: String, id: String): ?VectorRecord
    func remove(collection: String, id: String): Bool

    func searchDense(query: VectorQuery): ArrayList<VectorHit>          // 默认 dense
    func searchDenseField(query: VectorQuery, field: String): ArrayList<VectorHit>  // title / content
    func searchSparse(query: SparseQuery): ArrayList<VectorHit>
    func rerank(collection: String, ids: ArrayList<String>,
                queryColbert: Array<Array<Float64>>): ArrayList<VectorHit>

    func count(collection: String): Int64
    func ids(collection: String, offset: Int64, limit: Int64): ArrayList<String>    // 按 (saveTime, id) 升序
    func buildIndex(collection: String, clusters!: Int64): Int64                    // IVF 训练/重建
    func indexClusters(collection: String): Int64

    func recover(collection: String): Int64                     // 清理未写完的记录
    func setTtl(collection: String, seconds: Int64): Unit       // <=0 立即过期，<0 取消
    func ttlOf(collection: String): Int64
    func purgeExpired(collection: String): Int64
    func exportTo(collection: String, target: VectorStore, targetCollection: String): Int64
}
```

`VectorRecord` 字段：`id`、`payload`（不透明 JSON）、`dense`、`sparse`、`colbert`、
`filters`（白名单字段，默认 `kind`/`save_day`/`tags`，可配置）、`vectors`（命名 dense，方案 C）、`saveTime`。

## 存储布局

前缀 `h:{collection}:`，与其它业务 key 隔离：

| key | 内容 |
|---|---|
| `d:{id}` | payload |
| `v:d:{id}` | 默认 dense（f32 小端） |
| `v:f:{name}:{id}` | 命名 dense（title / content） |
| `vf:{id}` | 命名 dense 的字段名单（覆盖写/删除时清理） |
| `v:s:{id}` | sparse（`token:weight,...` 文本） |
| `v:c:{id}:{part}` | colbert 分片（每片 ≤64KB） |
| `i:t:{token}:{id}` | 稀疏倒排 posting |
| `f:{field}:{value}:{id}` | 过滤索引（白名单字段，默认 kind / save_day / tags） |
| `fl:{id}` | 该记录的**全部** filters（`字段\u0001值` 用 `\u0002` 连接） |
| `hc:{collection}` | 集合登记（批量重建倒排时枚举用） |
| `h:__sys:filterFields` | 上次生效的过滤字段白名单（启动时比对，变了就重建） |
| `m:ivf` / `m:cent:{i}` / `i:c:{i}:{id}` / `i:r:{id}` | IVF 配置 / 簇心 / 桶成员 / 反向指针 |
| `m:ttl` | 集合 TTL（epoch 秒） |
| `r:{id}` | 就绪标记（两阶段写的最后一步） |
| `t:{id}` | saveTime（epoch 秒） |

## 编码与语义

- **两阶段写**：`payload → dense → sparse → colbert 分片 → 倒排 → ready`；读路径一律先校验 `r:{id}`；
- **f32 小端**，与 `f_llm.store.ColbertCodec` 字节兼容（同一条 colbert 可在 PG 列与本库之间搬移）；
- **colbert 分片**：96 token × 1024 维 ≈ 384KB，按 64KB 切片；
- **过滤**：同字段多值 OR、跨字段 AND；白名单外字段查询恒不命中；白名单可用 `setFilterFields([...])` 配置，改后需 `rebuildFilterEntries(collection)` 重建旧记录的索引；
- **IVF**：确定性 k-means（初始簇心等距抽样，10 轮），`nprobe` 默认 8，候选不足 `limit` 时回退全量扫描；
- **TTL**：过期集合读操作返回空；取消 TTL 后数据重新可见（未被 `purgeExpired` 时）。

## 过滤字段配置

默认只给 `kind` / `save_day` / `tags` 建倒排。要按别的字段（`namespace`、`userId` 等）在服务端过滤，两步：

```cangjie
store.setFilterFields(['kind', 'namespace', 'userId'])   // 影响之后的写入
store.rebuildFilterEntries('u1:global')                  // 给已有记录补索引
```

- 名称会去空白、转小写、去重；传空数组直接抛错（空白名单会让所有过滤查询静默返回空）；
- `filterMetaKey` 保存**全部** filters，倒排只覆盖白名单字段，所以换白名单后能重建；
- 分隔符统一用控制字符：`\u0001` 分隔字段与值、`\u0002` 分隔条目——值里带 `;` `=` 也不会被拆坏；
- fhydra 侧读环境变量 `hydra_filterFields`（逗号分隔），启动时调用 `HydraRpc.configure()` → `applyFilterFields`。

**启动自动重建**：`applyFilterFields` 会把白名单与 `h:__sys:filterFields` 里记录的上一份比对，不同就枚举 `hc:` 登记的全部集合逐个 `rebuildFilterEntries`，然后写回新配置。因此改完环境变量重启即可，不需要人工跑重建；配置没变时不做任何扫描。

### 已知限制

| 限制 | 具体表现 | 应对 |
|---|---|---|
| **重建是 O(记录数) 的全量扫描** | `rebuildFilterEntries` 逐条 `get` 记录、删旧倒排、按新白名单重写；集合越大越慢，且期间占用读带宽 | 只在白名单真正变化时触发（配置未变不做扫描）；超大库建议在低峰期改配置，或按集合分批 `rebuildFilterEntries` 自己控制节奏 |
| **重建非原子** | 没有事务/快照：中途崩溃会留下「部分记录已重建、部分仍是旧索引」的中间态 | 配置写回发生在重建**之后**，所以崩溃下次启动仍会判定「配置已变」并重新扫一遍，可自愈；若不想等下次启动，手工再调一次 `applyFilterFields` 即可 |
| **值内的 `,` 会被当作多值分隔符** | `filters = {"tags": "a,b"}` 表示 `a` 或 `b` 两个值（OR），不是单个值 `a,b`；值本身含逗号时会被拆开，导致过滤命中的是拆分后的片段 | 需要「值里有逗号」的字段，换成不含逗号的值（如 `tag_a` / `tag_b`），或把该字段排除在白名单外，改用 payload 侧过滤 |

## 版本

| 版本 | 内容 |
|---|---|
| v0.1 | collection/record、f_store 落盘、暴力 dense |
| v0.2 | 稀疏倒排 + 权重累加 |
| v0.3 | colbert 落盘 + max-sim 重排 |
| v0.3.1 | f32 二进制 + colbert 64KB 分片 |
| v0.4 | IVF-Flat（k-means + nprobe + 增量挂桶） |
| v0.5 | 两阶段写、崩溃恢复、TTL、导出 |
| v0.5.1 | 过滤索引（kind / save_day / tags） |
| v0.6 | 方案 C：一条记录多命名 dense + saveTime 排序 |
| v0.6.1 | 过滤字段白名单可配置（`setFilterFields` / `rebuildFilterEntries`），meta 保存全部 filters |
| v0.6.2 | 白名单变更启动自动重建（`applyFilterFields`）、meta 分隔符统一为控制字符、集合登记 `hc:` |

---

## 其他公开 API

以下声明未在上文展开，按「模块级 / 类型」分组列出（`extend` 里的成员归到被扩展的类型）；完整语义见 `src/` 下对应文件。

- 模块级：`FStoreVectorStore`（class）、`SparseQuery`（class）、`VectorCodec`（class）、`VectorHit`（class）、`VectorMath`（class）、`VectorQuery`（class）
- `FStoreVectorStore`：`DEFAULT_FILTER_FIELDS`（let）、`close`（func）、`collections`（func）、`idsFiltered`（func）、`rebuildAllFilterEntries`（func）、`storedFilterFields`（func）
- `SparseQuery`：`let tokens: HashMap<Int64, Float64>`
- `VectorCodec`：`decodeColbert`（func）、`decodeDense`（func）、`encodeColbert`（func）、`encodeColbertParts`（func）、`encodeDense`（func）
- `VectorHit`：`let score: Float64`
- `VectorMath`：`cosine`（func）

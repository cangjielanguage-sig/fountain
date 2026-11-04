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
| `fl:{id}` | 该记录的过滤字段名单 |
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
- `filterMetaKey` 保存**全部** filters，倒排只覆盖白名单字段，所以换白名单后能靠 `rebuildFilterEntries` 重建；
- fhydra 侧读环境变量 `hydra_filterFields`（逗号分隔），启动时调用 `HydraRpc.configure()` 装配。

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

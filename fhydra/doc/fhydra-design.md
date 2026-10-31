# fhydra —— 自实现向量存储服务设计

> 版本 v0.1 ｜ 2026-10-28 ｜ 状态：设计待评审
>
> 本文是原 `docs/向量知识库模块设计.md`（v0.4）**拆分后的第二部分**；拆分完成后**原文档已删除**。
> 只负责「向量怎么存、怎么索引、怎么检索」，不再包含文档解析与 BGE-M3 访问。
> 第一部分（pandoc 转换 + BGE-M3 HTTP + 记忆/人设/编排）见 `../../f_llm/doc/f_llm-memory-design.md`。

---

## 0. 定位与边界

| 项 | 结论 |
|---|---|
| 形态 | **拆成两个模块**：`f_hydra/` 动态链接库（`output-type = "dynamic"`，向量与数据 CRUD）+ `fhydra/` 可执行文件（HTTP 服务，`fboot build` 产出二进制） |
| 依赖 | `f_hydra` → `f_store` + `f_data`/`f_log`/`f_config`/`f_concurrent`；`fhydra` → `f_hydra` + **`f_jsonrpc`**（HTTP 服务层，只管路由/鉴权/序列化；2026-10-31 由 `f_mvc` 改为 `f_jsonrpc`） |
| 无库默认 | f_llm 不装 PG/MySQL 时：**向量查询默认 `f_hydra`（进程内库）**，**非向量查询默认 `f_store`**；需要解耦部署时才用 `fhydra` 的 HTTP 接口 |
| **不依赖** | `f_llm`、任何 embedding 模型、pandoc —— 向量由调用方算好传入 |
| 调用方 | `f_llm` 的 `FhydraVectorStore` / `FhydraMemoryStore`；也可被其它项目直接 HTTP 调用 |
| 与数据库的关系 | fhydra 自身只用 `f_store` 落盘；`postgres/mysql/opengauss/mariadb` 是**并列的另一种选择**，由 f_llm 的存储实现直接连库，不经过 fhydra |

**解耦不变量**：fhydra 不知道「记忆」「人设」「知识库」这些业务概念，只认识
`collection → record → 向量`。业务语义（用户、工作空间、标题、正文）由 f_llm 决定如何编码进 `collection` 名与 `payload`。

---

## 1. 数据结构

### 1.1 逻辑模型

```
Collection（= f_llm 的一个 用户+命名空间；命名示例：记忆 `u{uid}:ws-{id}` / `u{uid}:global`、
会话 `u{uid}:s-{sessionId}`、知识库 `u{uid}:kb-{namespace}`）
  └── Record（一条记忆 / 一个文档块）
        ├── id: String           调用方生成的稳定 id（幂等写入）
        ├── payload: JSON        业务字段（title/content/save_time/kind…）
        ├── dense: f32[1024]     BGE-M3 稠密向量（一级召回，建索引）
        ├── sparse: {token:weight} BGE-M3 稀疏向量（一级召回，倒排）
        └── colbert: f32[N][1024] BGE-M3 多头向量（二级重排，不建索引；**落盘为二进制 f32[]**）
```

### 1.2 存储布局（单 Store + 前缀）

沿用源设计 v0.4 §5.1 的 key 方案，增加 `collection` 维度（值 = `u{userId}:{namespace}`）：

```
{c}:m:ver                         格式版本
{c}:m:cfg                         维度 / indexKind / nprobe / 簇数
{c}:m:cent:{clusterId}            簇心（IVF）
{c}:m:pqcb:{subspace}             PQ 码本（切到 IVF-PQ 后）

{c}:d:{recordId}                  payload JSON（≤ 64KB）
{c}:d:{recordId}:ready            就绪标记（两阶段写第二阶段）

{c}:v:d:{recordId}                dense 原始向量（dim*4 字节）
{c}:v:s:{recordId}                sparse 向量（JSON，token→weight）
{c}:v:c:{recordId}                colbert 原始向量（**二进制 f32[]**：count(4B) + count*dim*4B）
{c}:v:cp:{recordId}               colbert 池化向量（可选，long-doc 摘要用）
{c}:v:pq:{recordId}               PQ 码（m 字节）

{c}:i:t:{len2}{token}:{recordId}  稀疏倒排 posting（2 字节大端长度前缀防前缀撞）
{c}:i:c:{clusterId}:{recordId}    IVF 桶成员

{c}:f:{field}:{value}:{recordId}  过滤索引（仅白名单字段：kind / save_day / tags）
{c}:m:ttl                         集合级 TTL（epoch 秒；到期整集合失效）
```

**为什么单 Store + 前缀**（源文档 §5.2 结论，未变）：f_store 没有"库"概念，多实例 = 多套 WAL/compaction/Bloom；
前缀隔离查询零成本，跨 collection 检索天然支持。需要独立备份时用 `collection export/import` 接口导出前缀，而不是多 Store。

**value 上限**：SSTable 单文件 64MB，建议 value ≤ 64KB；`payload` 超限时由调用方截断或分片（f_llm 侧保证正文 ≤ 32KB/条）。

---

## 2. 索引

### 2.1 三路向量怎么用（沿用 v0.4 §3 的结论）

| 向量 | 用途 | 是否建索引 |
|---|---|---|
| dense | 语义召回 | ✅ IVF 系列（BruteForce → IVF-Flat → IVF-PQ 自动切换） |
| sparse | 词面精确匹配 | ✅ 倒排（前缀遍历 + 权重累加） |
| colbert | 细粒度重排 | ❌ 不建索引，只对一级候选现算 max-sim |

colbert 不建索引的理由不变：10 万块 × 150 token × 1024 维 ≈ 30GB，塞进 LSM 会把 compaction 打满。
重排只对 top-20 做，单条成本 ≈ 5.5ms（源文档实测 1.35μs/次点积）。

### 2.2 索引实现与切换

```cangjie
public enum IndexKind {
    | BruteForce
    | IvfFlat
    | IvfPq
}

public interface VectorIndex {
    func kind(): IndexKind
    func size(): Int64
    func build(samples: Iterator<(String, Array<Float32>)>): Unit
    func add(id: String, vec: Array<Float32>): Unit
    func remove(id: String): Unit
    func search(q: Array<Float32>, topK: Int64): Array<Hit>
    func flush(): Unit
}
```

阈值与自动切换、IVF-Flat ↔ IVF-PQ 共享粗量化器的迁移路径，完全沿用源文档 §6.2–6.4：
`n<2万 → BruteForce`，`n<50万 → IvfFlat`，`else → IvfPq`；切换是「写 target → 后台重建 → 原子切 cfg → 清旧结构」，
期间读旧索引、新数据进增量队列、失败可回退。

**不实现 HNSW**（决策不变，源文档 §6.6）：千万级内存 41GB vs IVF-PQ 640MB，端到端只差不到 1ms，
而删除/重建成本高。若后续确有极限延迟需求，走「IVF-PQ 粗排 + 原始向量重排」而不是自研图索引。

### 2.3 检索流程

```
1. 调用方已算好 query 的三路向量（fhydra 不做 embedding）
2. dense  → IVF nprobe 个簇 → 扫桶 → top-100
3. sparse → 倒排 posting 拉取 → 权重累加 → top-100
4. 融合：分数归一化（min-max）+ 加权（默认 dense 0.7 / sparse 0.3）+ 按 id 去重 → top-50
5. [可选] colbert 对 top-20 重排 → top-K
6. **业务权重**：`score ×= weight(payload.kind)`；权重来自请求的 `kind_weights`，缺省 1.0；
   先取 `topK × 2` 再乘权重，避免低权重记忆被提前挤掉
7. 返回 payload + 三路分量分数 + 生效权重
```

**权重查询不是 ANN 的一部分**：向量索引只负责「相似度」，kind 权重是检索后的标量调整。
放在 ANN 内部会把权重揉进距离度量，换权重就得重建索引——不可接受。

融合权重可在 collection 级配置（`{c}:m:cfg.weights`），默认 0.7/0.3。

### 2.4 payload 过滤：只做白名单字段的次级索引

**结论：值得做，但只做「白名单字段 + 值前缀」的倒排，不做任意 payload 路径索引。**

理由：

| 方案 | 写入成本 | 查询成本 | 风险 |
|---|---|---|---|
| 命中后内存过滤（现状） | 0 | 先取 top-100 再过滤，**过滤后可能凑不满 topK**，深分页更明显 | 数据量 > 10 万后召回塌陷 |
| 白名单字段倒排（建议） | 每条多 1–3 个 key，写放大 ~10% | 先按 `{c}:f:{field}:{value}` 取交集，再在交集中搜，毫秒级 | value 域可控（kind 十来个、save_day 按天、tag 有限） |
| 任意 JSON 路径索引 | key 数量随 payload 组合爆炸 | 需要 path 解析与类型归一 | 无法预估容量，必然失控 |

落地方式：

- 写入时只对 `kind`、`save_day`、`tags` 三类生成 `{c}:f:{field}:{value}:{recordId}`；
- **`save_day` 索引键按 UTC 日存储**：所有时间戳先归一为 UTC，键为 `{c}:f:save_day:{yyyy-MM-dd(UTC)}`；
  查询时把「服务端时区的某一天」换算成 UTC 区间（`[D 00:00, D+1 00:00)` 在服务端时区），
  该区间可能跨 1~2 个 UTC 日，取这些日键的并集；要精确到小时/分钟再按 `save_time` 在内存后过滤；
- 服务端时区取运行进程的机器配置（可被 `fhydra_timezone` 覆盖）。**存 UTC、算本地**：
  换时区不会让历史索引失真，也不会出现「昨天的记忆被算进今天」；
- 检索时 `filter` 里的字段必须是这三类之一，**其它字段直接 400**（不静默忽略，否则用户以为过滤生效了）；
- 多个过滤条件取交集后再做向量检索；交集为空直接返回空结果，不降级；
- 触发时机：fhydra **P2**（有真实数据量之后）。在 P1 之前，`filter` 只允许 `kind`（可在内存过滤），并在响应里标 `"filterMode":"post"` 让调用方知道深分页可能不满。

**`tag` 多值：支持，按「一条 tag 一个 key」展开**

一条记录可以带多个 tag（`payload.tags = ["cangjie","llm"]`），写入时每个 tag 生成一个过滤 key：

```
{c}:f:tag:cangjie:{id}
{c}:f:tag:llm:{id}
```

- **写入成本**：key 数 = tag 数，写放大与 tag 数线性相关；delete 时要按 `payload.tags` 逐个删 key（tag 列表必须留在 payload 或旁挂 `{c}:t:{id}`，否则删不干净）。
- **查询语义**（两种都提供，避免「心里想 AND 却写成 OR」的静默错误）：
  - `filter.tags: ["a","b"]` → **AND**：先取 `a` 的 id 集合、再取 `b`，求交集；
  - `filter.tags_any: ["a","b"]` → **OR**：两个集合并集；
  - 同时出现 `tags` 与 `tags_any` 时，先各自算再取交集。
- **成本**：取交集/并集的开销与「最短 posting 长度」成正比，通常远小于向量检索本身；但 tag 基数失控时 posting 会很长。
- **约束（必须，否则 key 会爆炸）**：每条记录 **≤ 8 个 tag**，每个 tag ≤ 32 字符、统一转小写并 trim；超限直接 400，不静默截断。
- **不建议**：把 tag 当自由文本（`"今天天气不错"` 这种）——那不是 tag，是正文，应在 `kind` 或全文检索里表达。

**建议**：值得做，`tags`（AND）与 `tags_any`（OR）都实现，配上上面的上限；如果实际使用中 tag 过滤占比很低，
可以只保留 `kind` 索引，把 tag 留给内存过滤——但一旦开放给用户，就必须先有上限。

### 2.5 collection 级 TTL

`f_store` 的 TTL 是 per-key 的，没有「整库过期」；集合级 TTL 用**统一写入 + 惰性判定**实现：

- 创建集合时 `POST /v1/collections/{c} {"ttl":"2h"}` 写 `{c}:m:ttl = now + 2h`；
- 该集合下所有写入（payload/向量/索引项）都用 `Store.add(key, value, expireAt: ttl)`；
- 读路径先查 `{c}:m:ttl`：不存在或已过期 → 视为集合不存在（404），并异步触发前缀清理；
- 刷新 TTL：再次 `POST` 同集合可续期（会话活跃时由调用方续期）。

**用途（对应需求）**：会话级存储 —— collection 名用 `u{userId}:s-{sessionId}`，创建时设 TTL（如会话超时 2h），会话结束显式 `DELETE`，或等 TTL 自然过期。过期后 key 由 f_store 的 TTL 机制回收，无需应用层扫描。

---

## 3. HTTP API

统一前缀 `/v1`，请求/响应均 `application/json`；错误用 `{code, message, detail}`，HTTP 状态码语义化（400/404/409/500）。

### 3.1 健康与统计

```
GET /health
→ {"status":"ok","version":"0.1.0","collections":3}

GET /v1/collections/{collection}/stats
→ {"collection":"u1:ws-9","records":1024,"indexKind":"IvfFlat",
   "denseDim":1024,"sizeBytes":5242880}
```

### 3.2 写入（幂等）

```
POST /v1/collections/{collection}/records
{
  "records": [
    {
      "id": "mem-1001",
      "payload": {"title":"…","content":"…","save_time":"2026-10-28T02:00:00Z"},  // 统一 UTC，不带本地偏移
      "dense": [0.01, …],                    // 1024 维，必填
      "sparse": {"123":0.42, …},              // 可选，key 是 bge-m3 token id（十进制字符串）
      "colbert_b64": "AAAA…"                  // 可选：f32 小端数组的 base64（最多 96 个 token 向量）
    }
  ]
}
→ {"written":1,"collection":"u1:ws-9"}
```

语义：**先写 payload/向量/索引项，最后写 ready**；同 id 覆盖写（先删旧索引项）。单条 payload ≤ 64KB，dense 维度必须与 collection 配置一致，否则 409。

**colbert 的线上格式与落盘格式不同**：HTTP 只能传 JSON，所以线上用 `colbert_b64`（f32 小端数组 base64）；**落盘固定为二进制 `f32[]`**（`{c}:v:c:{id}`），不存 JSON——同一份数据 JSON 体积约 3 倍，读写都要多一轮解析。二进制布局：`count(Int32 LE) + count × dim × Float32 LE`，宿主按小端读写（x86/aarch64 一致），跨语言只需 `struct.unpack('<i')` + `'<%df'`。

### 3.3 删除

```
DELETE /v1/collections/{collection}/records/{id}   → 204
POST   /v1/collections/{collection}/flush          → {"flushed":true}
```

删除写 tombstone，索引项立即从桶/倒排移除，空间由 compaction 回收。

### 3.4 检索

```
POST /v1/collections/{collection}/search
{
  "dense":  [0.02, …],                       // 至少给一路
  "sparse": {"token:123":0.8},
  "topK": 10,
  "rerank": false,                           // true 时用 colbert 重排（标题与正文都参与）
  "filter": {
    "kind": "note",                          // 白名单字段：kind / save_day / tags / tags_any
    "save_day": "2026-10-28",                // 服务端时区的本地日；内部展开成 1~2 个 UTC 日键
    "tags": ["cangjie", "llm"],              // AND：两个 tag 都要有
    "tags_any": ["draft", "wip"]             // OR：命中任一即可
  },
  "kind_weights": {"session": 0.3, "task": 0.6}   // 可选：按 payload.kind 乘权重，缺省 1.0；固定值由调用方传，无 collection 级配置
}
→
{
  "results": [
    {"id":"mem-1001","score":0.83,"weight":0.3,
     "components":{"dense":0.81,"sparse":0.42,"colbert":0.77},
     "payload":{"title":"…","content":"…","kind":"session"}}
  ]
}
```

跨 collection 检索：`POST /v1/search`，body 带 `"collections":["u1:ws-9","u1:global"]`，结果合并排序并附 `collection` 字段。

### 3.5 集合管理

```
GET    /v1/collections                       → {"collections":["u1:ws-9","u1:global"]}
POST   /v1/collections/{collection}          → 201  body: {"ttl":"2h"}（可选，续期同接口）
DELETE /v1/collections/{collection}          → 204（前缀遍历 + tombstone，异步回收）
POST   /v1/collections/{collection}/reindex  → 202（后台按阈值重建索引）
POST   /v1/collections/{collection}/export   → 200 application/zip（Markdown 文档集合，见 §3.7）
POST   /v1/collections/import                → 202 multipart/zip（同 §3.7 格式）
```

### 3.7 导出 / 导入：Markdown 集合 + zip

**不用 JSONL，也不拷数据目录**：导出物要能被人直接读、能进 Git、能被另一台机器上的工具处理，所以正文用 Markdown、结构用 zip。

```
{collection}-{yyyyMMddHHmmss}.zip
├── README.md                  # 集合索引：记录数、字段说明、生成时间、fhydra 版本
├── manifest.json              # 机器可读：每条记录 id / 文件名 / 正文校验和
└── docs/{id}.md               # YAML front matter（id/title/kind/save_time/tags）+ 正文
```

- **导出物不含任何向量**（dense / sparse / colbert 都不带）：向量是「由 embedding 模型 + 当前版本」算出来的派生数据，
  跨机器、跨模型版本搬运会悄悄失真；导入时统一由调用方（f_llm）重新 embedding，fhydra 不猜；
- 正文与元数据放 Markdown，导出物可被人直接读、能进 Git、能被其它工具处理；
- 导入时按 `manifest.json` 逐条 upsert；缺向量就是缺，不构造占位向量；
- 打包依赖 `f_zip`（**模块已就绪**，2026-10-29 从 `sts/1.3.x` 合入）。**不另写 zip 容器、也不做 tar 兜底**，
  读写 zip 统一走 `f_zip`，避免两套实现与两套测试。

### 3.6 鉴权

`fhydra_auth_token` 配置非空时，所有 `/v1/*` 要求 `Authorization: Bearer <token>`；`/health` 放行。
**不做用户体系**：`collection` 名已经由调用方按 `u{userId}:{namespace}` 编好，fhydra 不解释它。

---

## 4. 一致性与恢复

| 场景 | 处理 |
|---|---|
| 写入中途崩溃 | `ready` 未写 → 查询不可见；启动时/后台 GC 扫描无 ready 的 `d:` 记录并清理关联向量/索引项 |
| 索引与数据不一致 | `m:cfg` 记录 `indexVersion`；重建期间双写增量队列，切换后回放 |
| 删除后仍被召回 | 检索命中时校验 `d:{id}` 存在且 ready，否则丢弃并异步清索引项 |
| WAL 丢失 | 依赖 f_store 自身 WAL；fhydra 每 N 次写调用 `syncWAL()`（默认 500） |
| 重建失败 | `m:rebuild:target` 标记保留，旧索引继续服务，重启后重试 |
| 集合 TTL 到期 | 读路径按 `m:ttl` 判定为不存在（404）；key 由 f_store 的 TTL 回收，残留索引项由后台按前缀清理 |

---

## 5. f_llm 侧契约

f_llm 提供两个适配器，均实现同一组存储接口：

```cangjie
public class FhydraVectorStore <: VectorStore {
    public init(baseUrl!: String, token!: String = '', timeout!: Duration = Duration.second * 30)
    public func upsert(collection: String, records: ArrayList<VectorRecord>): Unit
    public func search(collection: String, query: VectorQuery): ArrayList<VectorHit>
    public func remove(collection: String, id: String): Unit
}

public class FhydraMemoryStore <: MemoryStore { /* 见 ../../f_llm/doc/f_llm-memory-design.md §5 */ }
```

- 序列化：dense 用 JSON 数字数组；**colbert 用 `colbert_b64`（f32 小端 base64）**，落盘为二进制 `f32[]`，**不做 f16 压缩**（避免精度争议）；
- 超时/重试：连接 1s、读 30s；5xx 重试 2 次（指数退避），4xx 不重试；
- 熔断：连续 5 次失败后 60s 内快速失败，与 `CircuitBreaker` 同参数；
- 版本协商：启动时 `GET /health` 校验 `version` 主版本，不匹配启动失败。

---

## 6. 部署与运维

| 项 | 默认 | 配置键 |
|---|---|---|
| 端口 | 8848 | `fhydra_port` |
| 数据目录 | `./data/fhydra` | `fhydra_path` |
| 鉴权 token | 空（不鉴权） | `fhydra_auth_token` |
| 同步 WAL 间隔 | 500 次写 | `fhydra_sync_every` |
| 索引策略 | auto | `fhydra_index_policy`（auto/bruteforce/ivf_flat/ivf_pq） |
| 单 collection 上限 | 500 万条 | `fhydra_max_records`（超限拒绝写，不静默丢） |
| 时区 | 系统时区 | `fhydra_timezone`（如 `Asia/Shanghai`；存 UTC，按此换算本地日） |

启动：`fboot build && ./fhydra`；`fhydra --version` 打印版本与 f_store 版本。
**启动日志必须显式打印生效时区**，格式固定为一行，便于排查「跨日查询差一天」：

```
[timezone] effective=Asia/Shanghai source=fhydra_timezone system=Etc/UTC
```

`source` 为 `system`（未配置）或 `fhydra_timezone`（被覆盖）；两者不一致时这一行就是唯一线索。
备份：停写 → 拷数据目录；在线备份用 `POST /v1/collections/{c}/export` 导出 **Markdown 集合 + zip**（§3.7，打包走 `f_zip`）。
会话级集合不必备份：用 `u{uid}:s-{sessionId}` + TTL，会话结束即消失。

---

## 7. 测试计划

| 层 | 用例 |
|---|---|
| 存储 | 两阶段写：ready 前查询不可见；崩溃残留被 GC 清理 |
| 索引 | BruteForce 与 IVF-Flat 在同一数据集上 top-10 召回重合 ≥ 0.95 |
| 切换 | 2 万条触发 IvfFlat，5 万条切 IvfPq 后查询不中断、可回滚 |
| 稀疏 | 倒排 posting 按 id 有序；token 长度前缀不撞（`的` vs `的确`） |
| 重排 | colbert 开关只影响排序不影响候选集 |
| HTTP | 幂等写入、维度不符 409、collection 不存在 404、鉴权 401 |
| 并发 | 写与检索并发 10 万次无 panic、无数据竞争（`--sanitize` 若有） |

---

## 8. 决策记录（2026-10-28 定稿）

| 问题 | 决定 |
|---|---|
| payload 过滤要不要建索引 | **要做**，但只做白名单字段（`kind` / `save_day` / `tags`）的值前缀倒排，不做任意 JSON 路径；排在 P2（§2.4） |
| `tag` 是否支持多值 | **支持**：一条 tag 一个 key；`tags` = AND、`tags_any` = OR；每条 ≤ 8 个、每个 ≤ 32 字符（§2.4） |
| `save_day` 用哪个时区 | **存 UTC 日、算服务端本地日**：写入归一 UTC；查询把本地日换算成 1~2 个 UTC 日键取并集（§2.4） |
| colbert 存 JSON 还是 f32[] | **f32[] 二进制**；线上 JSON 用 `colbert_b64` 承载（§3.2） |
| collection 级 TTL | **支持**；用于会话级集合，`u{uid}:s-{sessionId}` + `ttl`，会话结束即消失（§2.5） |
| 导出/导入格式 | **Markdown 文档集合 + zip**（`README.md` + `docs/*.md` + `manifest.json`），打包统一走 `f_zip`（§3.7） |
| 导出是否带向量 | **一律不带**：dense / sparse / colbert 都不导出，导入时由 f_llm 重新 embedding（§3.7） |
| 生效时区如何观测 | **启动日志打印一行**：`effective=… source=system\|fhydra_timezone`（§6） |
| 导出物记不记模型名/维度 | **不记**：`README.md` 只记元数据（记录数、生成时间、版本），不记模型名与维度，也不记向量（§3.7） |
| 检索是否支持权重 | **支持**：`kind_weights` 在融合后乘到分数上，不进 ANN（§2.3、§3.4） |
| `kind_weights` 是否要 collection 级默认 | **不要**：权重是固定值，由调用方每次传入，不定义集合级/多维配置（§3.4） |

剩余未决：**无**（本轮问题全部收敛）。

# fhydra JSON-RPC 接口清单（v1 草案）

> 2026-10-31 ｜ 状态：待确认（确认后才写服务端）
>
> 服务端 = `fhydra`（动态库 + `fboot run`），HTTP 层用 `f_jsonrpc`，数据层用 `f_hydra`。

---

## 1. 传输与部署

| 项 | 约定 |
|---|---|
| 进程 | `fboot run <target> --dylibPattern='(fhydra)'`，端口读 `mvc_port`（与 fjsonrpcdemo 一致） |
| 端点 | `POST /rpc`（全部命名空间）与 `POST /rpc/hydra`（限定 `hydra`） |
| 协议 | JSON-RPC 2.0；支持批量数组与通知（无 `id` 不返回响应） |
| 头 | 必须 `Content-Type: application/json`（否则 415）、`Accept: application/json`（否则 406） |
| 命名空间 | 类上 `@JsonRpc[namespace: hydra]`，方法名即 `hydra.<method>` |
| 超时 | 每个方法用 `@JsonRpcMeta['描述', '5s']` 声明；见方法表 |

## 2. 通用数据约定

### 2.1 向量

v1 用 JSON 数组（`Float64`）：

```json
"dense": [0.013, -0.24, "…共 1024 个"]
```

- 服务端写入时按 **f32** 落盘（与 `VectorCodec` 一致），读回是 f32 精度；
- 维度不固定（由数据决定），同一 collection 内应保持一致；
- **待确认**：是否增加 `denseB64` / `colbertB64`（f32 小端 + Base64）作为大向量的高效通道。

### 2.2 sparse

```json
"sparse": {"124084": 0.26, "6": 0.087}
```

key 是字符串形式的 token id（JSON 限制），服务端转 `Int64`。

### 2.3 filters

只支持白名单字段，跨字段 AND、同字段多值 OR：

```json
"filters": {"kind": "note", "save_day": "20261031", "tags": "a,b"}
```

未在 `kind` / `save_day` / `tags` 内的字段**不报错**，但该条件永不命中（0 结果）。

### 2.4 hits

```json
{"id": "r1", "payload": "{\"title\":\"…\"}", "score": 0.87}
```

`score`：dense 为余弦（-1~1），sparse 为 `Σ 查询权重 × 记录权重`，rerank 为 max-sim 均值（0~1）。

## 3. 方法表

| 方法 | 参数 | 返回 | 超时 |
|---|---|---|---|
| `hydra.health` | `{}` | `{"status":"ok","version":"1.3.17"}` | 1s |
| `hydra.upsert` | `collection,id,payload,dense,sparse?,colbert?,filters?` | `{"ok":true}` | 5s |
| `hydra.get` | `collection,id` | record 或 `null` | 2s |
| `hydra.remove` | `collection,id` | `{"removed":bool}` | 2s |
| `hydra.searchDense` | `collection,dense,limit,filters?` | `{"hits":[…]}` | 5s |
| `hydra.searchSparse` | `collection,tokens,limit,filters?` | `{"hits":[…]}` | 5s |
| `hydra.rerank` | `collection,ids,colbert` | `{"hits":[…]}` | 5s |
| `hydra.count` | `collection` | `{"count":n}` | 2s |
| `hydra.ids` | `collection,offset,limit` | `{"ids":[…]}` | 2s |
| `hydra.buildIndex` | `collection,clusters?` | `{"clusters":n}` | 60s |
| `hydra.indexClusters` | `collection` | `{"clusters":n}` | 1s |
| `hydra.recover` | `collection` | `{"purged":n}` | 60s |
| `hydra.setTtl` | `collection,seconds` | `{"ok":true}` | 2s |
| `hydra.ttl` | `collection` | `{"ttl":epochSeconds}` | 1s |
| `hydra.purgeExpired` | `collection` | `{"purgedKeys":n}` | 60s |
| `hydra.export` | `collection,targetCollection` | `{"exported":n}` | 60s |

说明：

- `hydra.export` 只在**同一服务进程内**复制 collection（跨服务器迁移由客户端 `ids` + `get` + `upsert` 完成）；
- `hydra.searchDense` 未建 IVF 时自动暴力扫描，行为一致；`clusters=0` 表示按 `√n` 估算簇数；
- `hydra.get` 对「未就绪 / 已删除 / 过期」一律返回 `null`，不区分——避免泄漏写入中间态。

## 4. 示例

### 4.1 upsert

```json
{"jsonrpc":"2.0","id":1,"method":"hydra.upsert","params":{
  "collection":"u0:global",
  "id":"mem-1",
  "payload":"{\"title\":\"偏好\",\"kind\":\"preference\"}",
  "dense":[0.01,0.02],
  "sparse":{"6":0.26},
  "colbert":[[0.01,0.02]],
  "filters":{"kind":"preference","save_day":"20261031","tags":"pref,ui"}
}}
```

```json
{"jsonrpc":"2.0","id":1,"result":{"ok":true}}
```

### 4.2 searchDense

```json
{"jsonrpc":"2.0","id":2,"method":"hydra.searchDense","params":{
  "collection":"u0:global","dense":[0.01,0.02],"limit":5,
  "filters":{"kind":"preference"}
}}
```

```json
{"jsonrpc":"2.0","id":2,"result":{"hits":[
  {"id":"mem-1","payload":"{…}","score":0.98}
]}}
```

### 4.3 参数错误

```json
{"jsonrpc":"2.0","id":3,"error":{"code":-32602,"message":"limit must be positive"}}
```

## 5. 错误码

| code | 含义 | 触发场景 |
|---|---|---|
| -32700 | Parse error | 非法 JSON |
| -32600 | Invalid request | 缺 `method` / 非法 `jsonrpc` |
| -32601 | Method not found | 拼错方法名 |
| -32602 | Invalid params | 缺必填、`limit<=0`、`clusters<0`、向量为空 |
| -32603 | Internal error | `f_store` IO、未捕获异常 |
| 1001 | Dimension mismatch | 查询向量长度与记录不一致（当前实现是跳过该记录；API 层需要显式返回） |
| 1002 | Invalid vector | 含 NaN/Inf |
| 1003 | Store unavailable | 数据目录不可写/已关闭 |

## 6. 与 f_llm 的对接点

f_llm 的 `FhydraVectorStore`（待实现）按下面映射调用：

| f_llm 操作 | RPC |
|---|---|
| `upsert(record)` | `hydra.upsert` |
| `get(id)` | `hydra.get` |
| `remove(id)` | `hydra.remove` |
| `searchDense(dense, limit, filters)` | `hydra.searchDense` |
| `searchSparse(tokens, limit, filters)` | `hydra.searchSparse` |
| `rerank(ids, colbert)` | `hydra.rerank` |
| `rebuild`（运维） | `hydra.recover` / `hydra.buildIndex` |

collection 命名由 f_llm 决定（记忆 `u{uid}:global`、知识 `u{uid}:kb-{ns}`）。

## 7. 待确认项

1. **鉴权**：f_jsonrpc 当前无 token/签名机制；fhydra 是否需要（内网部署可先不做）？
2. **大向量通道**：`dense` 1024 个 f64 约 10KB/条，是否加 Base64 f32 字段？
3. **批量 upsert**：f_llm 重建索引时逐条调用会放大 RTT，是否加 `hydra.upsertBatch`（≤100 条）？
4. **健康检查**：`hydra.health` 走 JSON-RPC 即可，还是另开 `GET /health`（供 K8s/lb）？
5. **服务启动**：`fhydra` 用 fboot 加载 `@Controller`（与 fjsonrpcdemo 一致），还是自带 `main` 直接起 f_mvc Server？

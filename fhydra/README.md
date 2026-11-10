# fhydra

`f_hydra` 的 JSON-RPC 服务（可执行文件，自带 `main`，HTTP 层用 `f_jsonrpc`）。

## 构建与运行

```bash
cd fhydra
cjpm build

export hydra_dataPath=./data/fhydra     # 数据目录（默认 ./data/fhydra）
export hydra_secret=change-me           # 共享密钥；未配置时除 health 外全部拒绝
export mvc_port=18081                   # HTTP 端口（f_mvc 约定）
./target/release/bin/main
```

运行依赖动态库（`f_hydra` / `f_mvc` / `f_jsonrpc` 等），需要设置 `LD_LIBRARY_PATH`；
可直接参考 `scripts/e2e.sh` 的写法。

## 协议

| 项 | 约定 |
|---|---|
| 端点 | `POST /rpc`、`POST /rpc/hydra` |
| 协议 | JSON-RPC 2.0（支持批量与通知） |
| 头 | `Content-Type: application/json`、`Accept: application/json` |
| 鉴权 | `X-Hydra-Key: $hydra_secret`（`hydra.health` 除外） |
| 参数 | 方法参数是单个对象，字段名固定为 `param` |
| 向量 | `dense` 数组或 `denseB64`（f32 小端 Base64，优先） |

完整接口见 [`doc/fhydra-jsonrpc-api.md`](doc/fhydra-jsonrpc-api.md)。

## 方法（16）

`health` / `upsert` / `upsertBatch` / `get` / `remove` / `searchDense` / `searchSparse` /
`rerank` / `count` / `ids` / `buildIndex` / `indexClusters` / `recover` / `setTtl` / `ttl` /
`purgeExpired` / `export`

说明：

- 复合结果均为**对象**：`{"hits":[…]}`、`{found,id,payload,dense,titleDense,contentDense,tokenIds,weights,colbert,saveTime}`、`{ids:[…]}`；
- `upsert` 接受 `dense`/`denseB64` 与命名向量 `titleDense`/`contentDense`，并透传 `sparse`（`tokenIds`+`weights`）；
- `ids` 按 `(saveTime, id)` 升序。

## 冒烟与 conformance

```bash
# 服务自检：health / 鉴权 / upsert(denseB64) / searchDense / get / ids / count
bash scripts/e2e.sh

# 远程 conformance：起服务 → 跑 f_llm 全量测试 → 对照「进程内 f_hydra」与「远程 fhydra」
bash scripts/conformance.sh
```

`conformance.sh` 需要先 `cjpm build`（f_hydra 与本模块）；目标输出 `CONFORMANCE_OK`。

## 与 f_llm 的关系

f_llm 通过 `llm_memoryStore=fhydra` 使用本服务：

```cj
Config.set<String>([
    ('llm_memoryStore', 'fhydra'),
    ('llm_hydraUrl', 'http://127.0.0.1:18081/rpc'),
    ('llm_hydraSecret', 'change-me')
])
```

进程内默认是 `f_hydra`（`llm_hydraPath`），两者共用同一份仓库/知识实现，只换传输层。

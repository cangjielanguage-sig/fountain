# fhydra

`f_hydra` 的 JSON-RPC 服务（可执行文件，自带 `main`，HTTP 层用 `f_jsonrpc`）。

## 构建与运行

```bash
cd fhydra
cjpm build

export hydra_dataPath=./data/fhydra     # 数据目录（默认 ./data/fhydra）
export hydra_secret=change-me           # 共享密钥（未配置时除 health 外全部拒绝）
export mvc_port=18081                   # HTTP 端口（f_mvc 约定）
./target/release/bin/main
```

依赖动态库（`f_hydra` / `f_mvc` / `f_jsonrpc` 等）需要设 `LD_LIBRARY_PATH`，
可直接用 `scripts/e2e.sh` 的写法。

## 约定

| 项 | 说明 |
|---|---|
| 端点 | `POST /rpc`、`POST /rpc/hydra` |
| 鉴权 | 头 `X-Hydra-Key: $hydra_secret`（`hydra.health` 除外） |
| 参数 | 单个对象参数名固定为 `param` / `params` |
| 向量 | `dense` 数组或 `denseB64`（f32 小端 Base64，优先） |

接口清单见 [`doc/fhydra-jsonrpc-api.md`](doc/fhydra-jsonrpc-api.md)。

## 冒烟

```bash
bash scripts/e2e.sh
```

覆盖：健康检查（免鉴权）、受保护方法缺密钥被拒（`-32023`）、
`upsert`（`denseB64`）→ `searchDense` → `count`。

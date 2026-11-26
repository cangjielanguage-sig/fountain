# fhydra

The JSON-RPC service for `f_hydra` (an executable with its own `main`; the HTTP layer uses `f_jsonrpc`).

## Build and run

```bash
cd fhydra
cjpm build

export hydra_dataPath=./data/fhydra     # data directory (default ./data/fhydra)
export hydra_secret=change-me           # shared secret; without it everything except health is rejected
export mvc_port=18081                   # HTTP port (f_mvc convention)
./target/release/bin/main
```

Running requires the dynamic libraries (`f_hydra` / `f_mvc` / `f_jsonrpc` etc.), so `LD_LIBRARY_PATH` must be set; see `scripts/e2e.sh` for a working example.

## Protocol

| Item | Contract |
|---|---|
| Endpoint | `POST /rpc`, `POST /rpc/hydra` |
| Protocol | JSON-RPC 2.0 (batch and notifications supported) |
| Headers | `Content-Type: application/json`, `Accept: application/json` |
| Authentication | `X-Hydra-Key: $hydra_secret` (except `hydra.health`) |
| Parameters | Method parameters are a single object whose field name is always `param` |
| Vectors | `dense` array or `denseB64` (f32 little-endian Base64, preferred) |

The full interface is documented in [`doc/fhydra-jsonrpc-api.md`](doc/fhydra-jsonrpc-api.md).

## Methods (16)

`health` / `upsert` / `upsertBatch` / `get` / `remove` / `searchDense` / `searchSparse` /
`rerank` / `count` / `ids` / `buildIndex` / `indexClusters` / `recover` / `setTtl` / `ttl` /
`purgeExpired` / `export`

Notes:

- Composite results are always **objects**: `{"hits":[…]}` / `{found,id,payload,dense,titleDense,contentDense,tokenIds,weights,colbert,saveTime}` / `{ids:[…]}`;
- `upsert` accepts `dense` / `denseB64` plus the named vectors `titleDense` / `contentDense`, and passes `sparse` (`tokenIds` + `weights`) through;
- `ids` are ordered by `(saveTime, id)` ascending.

## Smoke tests and conformance

```bash
# Service self-check: health / auth / upsert(denseB64) / searchDense / get / ids / count
bash scripts/e2e.sh

# Remote conformance: start the service → run the full f_llm test suite → compare in-process f_hydra with remote fhydra
bash scripts/conformance.sh
```

`conformance.sh` requires `cjpm build` first (both f_hydra and this module); success prints `CONFORMANCE_OK`.

## Relationship with f_llm

f_llm uses this service through `llm_memoryStore=fhydra`:

```cj
Config.set<String>([
    ('llm_memoryStore', 'fhydra'),
    ('llm_hydraUrl', 'http://127.0.0.1:18081/rpc'),
    ('llm_hydraSecret', 'change-me')
])
```

In-process the default is `f_hydra` (`llm_hydraPath`); both share the same store / knowledge implementation and differ only in the transport.

---

## Other public API

The declarations below are not expanded above; they are grouped by module level and by type (members declared in `extend` blocks are listed under the extended type). See the corresponding files under `src/` for the full semantics.

- Module level: `public class BuildIndexParam`, `public class CollectionParam`, `public class ExportParam`, `public class GetParam`, `public class HitDto`, `public class HitsDto`, `HydraAuth` (class), `public class HydraRpc`, `public class IdsDto`, `public class IdsParam`, `public class RecordDto`, `public class RemoveParam`, `public class RerankParam`, `public class SearchParam`, `public class SparseParam`, `public class TtlParam`, `public class UpsertParam`
- `BuildIndexParam`: `var clusters: Int64 = 0`, `var collection: String =`
- `CollectionParam`: `var collection: String =`
- `ExportParam`: `var collection: String =`, `var targetCollection: String =`
- `GetParam`: `var collection: String =`
- `HitDto`: `var score: Float64 = 0.0`
- `HydraAuth`: `require` (func)
- `HydraRpc`: `configure` (func)
- `IdsParam`: `var collection: String =`, `filters` (var), `var limit: Int64 = 100`, `var offset: Int64 = 0`
- `RemoveParam`: `var collection: String =`
- `RerankParam`: `var collection: String =`
- `SearchParam`: `var collection: String =`, `field` (var), `var kind: String =`, `var limit: Int64 = 10`, `var saveDay: String =`, `var tags: String =`
- `SparseParam`: `var collection: String =`, `var kind: String =`, `var limit: Int64 = 10`, `var saveDay: String =`, `var tags: String =`
- `TtlParam`: `var collection: String =`, `var seconds: Int64 = 0`
- `UpsertParam`: `var collection: String =`, `var kind: String =`, `var saveDay: String =`, `var tags: String =`

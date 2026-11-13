# f_hydra

In-process vector store (dynamic library): `collection → record → three-way vectors`, persisted through `f_store`, **no database required**.

It is the default content family of f_llm (`llm_memoryStore=f_hydra`); for remote deployments `fhydra` exposes the same capability over JSON-RPC.

## Build and test

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

    func searchDense(query: VectorQuery): ArrayList<VectorHit>          // default dense
    func searchDenseField(query: VectorQuery, field: String): ArrayList<VectorHit>  // title / content
    func searchSparse(query: SparseQuery): ArrayList<VectorHit>
    func rerank(collection: String, ids: ArrayList<String>,
                queryColbert: Array<Array<Float64>>): ArrayList<VectorHit>

    func count(collection: String): Int64
    func ids(collection: String, offset: Int64, limit: Int64): ArrayList<String>    // ascending by (saveTime, id)
    func buildIndex(collection: String, clusters!: Int64): Int64                    // IVF train / rebuild
    func indexClusters(collection: String): Int64

    func recover(collection: String): Int64                     // clean up half-written records
    func setTtl(collection: String, seconds: Int64): Unit       // <=0 expires immediately, <0 cancels
    func ttlOf(collection: String): Int64
    func purgeExpired(collection: String): Int64
    func exportTo(collection: String, target: VectorStore, targetCollection: String): Int64
}
```

`VectorRecord` fields: `id`, `payload` (opaque JSON), `dense`, `sparse`, `colbert`,
`filters` (whitelisted fields, `kind`/`save_day`/`tags` by default, configurable), `vectors` (named dense, scheme C), `saveTime`.

## Storage layout

Prefix `h:{collection}:`, isolated from other business keys:

| key | Content |
|---|---|
| `d:{id}` | payload |
| `v:d:{id}` | default dense (f32 little endian) |
| `v:f:{name}:{id}` | named dense (title / content) |
| `vf:{id}` | list of named dense fields (cleaned up on overwrite/delete) |
| `v:s:{id}` | sparse (`token:weight,...` text) |
| `v:c:{id}:{part}` | colbert shard (each shard ≤ 64KB) |
| `i:t:{token}:{id}` | sparse inverted posting |
| `f:{field}:{value}:{id}` | filter index (whitelisted fields, kind / save_day / tags by default) |
| `fl:{id}` | **all** filters of the record (`field\u0001value` joined by `\u0002`) |
| `hc:{collection}` | collection registry (used to enumerate when rebuilding postings in bulk) |
| `h:__sys:filterFields` | whitelist in effect last time (compared at startup; rebuilt when changed) |
| `m:ivf` / `m:cent:{i}` / `i:c:{i}:{id}` / `i:r:{id}` | IVF config / centroids / bucket members / back-pointers |
| `m:ttl` | collection TTL (epoch seconds) |
| `r:{id}` | ready marker (last step of the two-phase write) |
| `t:{id}` | saveTime (epoch seconds) |

## Encoding and semantics

- **Two-phase write**: `payload → dense → sparse → colbert shards → postings → ready`; every read path checks `r:{id}` first;
- **f32 little endian**, byte-compatible with `f_llm.store.ColbertCodec` (the same colbert can move between a PG column and this store);
- **colbert sharding**: 96 tokens × 1024 dims ≈ 384KB, sliced into 64KB chunks;
- **Filtering**: multiple values of one field are OR'ed, different fields are AND'ed; queries on non-whitelisted fields never match; the whitelist is configurable via `setFilterFields([...])`, and existing records need `rebuildFilterEntries(collection)` afterwards;
- **IVF**: deterministic k-means (evenly sampled initial centroids, 10 rounds), `nprobe` defaults to 8, falls back to a full scan when candidates are fewer than `limit`;
- **TTL**: reads on an expired collection return nothing; after cancelling the TTL the data becomes visible again (unless `purgeExpired` already removed it).

## Filter field configuration

Only `kind` / `save_day` / `tags` get postings by default. To filter on other fields (`namespace`, `userId`, …) server-side, do two steps:

```cangjie
store.setFilterFields(['kind', 'namespace', 'userId'])   // affects subsequent writes
store.rebuildFilterEntries('u1:global')                  // backfill the index for existing records
```

- Names are trimmed, lowercased and deduplicated; an empty array throws — a blank whitelist would make every filtered query silently return nothing;
- `filterMetaKey` keeps **all** filters while the postings only cover whitelisted fields, which is what makes a rebuild possible after changing the whitelist;
- Separators are control characters: `\u0001` between field and value, `\u0002` between entries — values containing `;` or `=` are not split;
- On the fhydra side the environment variable `hydra_filterFields` (comma separated) is read at startup, and `HydraRpc.configure()` calls `applyFilterFields`.

**Automatic rebuild at startup**: `applyFilterFields` compares the whitelist with the previous one stored in `h:__sys:filterFields`; when they differ it enumerates every collection registered under `hc:` and calls `rebuildFilterEntries` on each, then writes the new configuration back. Changing the environment variable and restarting is therefore enough — no manual rebuild. Nothing is scanned when the configuration is unchanged.

### Known limitations

| Limitation | Behaviour | Mitigation |
|---|---|---|
| **Rebuild is an O(records) full scan** | `rebuildFilterEntries` gets each record, deletes the old postings and rewrites them per the new whitelist; the larger the collection, the slower it gets, and it competes for read bandwidth | Only triggered when the whitelist really changes (no scan when unchanged); for very large stores change the configuration off-peak, or call `rebuildFilterEntries` collection by collection at your own pace |
| **Rebuild is not atomic** | No transaction/snapshot: a crash midway leaves a mix of rebuilt and stale records | The configuration is written back **after** the rebuild, so the next startup still sees "configuration changed" and scans again — self-healing; to avoid waiting, call `applyFilterFields` once manually |
| **A `,` inside a value is treated as a multi-value separator** | `filters = {"tags": "a,b"}` means `a` OR `b`, not the single value `a,b`; a value containing a comma gets split and filtering then matches the fragments | For fields whose values contain commas, use values without commas (`tag_a` / `tag_b`) or keep the field out of the whitelist and filter on the payload side |

## Versions

| Version | Content |
|---|---|
| v0.1 | collection/record, f_store persistence, brute-force dense |
| v0.2 | sparse inverted index + weight accumulation |
| v0.3 | colbert persistence + max-sim rerank |
| v0.3.1 | f32 binary + 64KB colbert sharding |
| v0.4 | IVF-Flat (k-means + nprobe + incremental bucketing) |
| v0.5 | two-phase write, crash recovery, TTL, export |
| v0.5.1 | filter index (kind / save_day / tags) |
| v0.6 | scheme C: multiple named dense vectors per record + saveTime ordering |
| v0.6.1 | configurable filter whitelist (`setFilterFields` / `rebuildFilterEntries`), meta keeps all filters |
| v0.6.2 | automatic rebuild on whitelist change (`applyFilterFields`), control-character separators, collection registry `hc:` |

---

## Other public API

The declarations below are not expanded above; they are grouped by module level and by type (members declared in `extend` blocks are listed under the extended type). See the corresponding files under `src/` for the full semantics.

- Module level: `FStoreVectorStore` (class), `SparseQuery` (class), `VectorCodec` (class), `VectorHit` (class), `VectorMath` (class), `VectorQuery` (class)
- `FStoreVectorStore`: `DEFAULT_FILTER_FIELDS` (let), `close` (func), `collections` (func), `idsFiltered` (func), `rebuildAllFilterEntries` (func), `storedFilterFields` (func)
- `SparseQuery`: `let tokens: HashMap<Int64, Float64>`
- `VectorCodec`: `decodeColbert` (func), `decodeDense` (func), `encodeColbert` (func), `encodeColbertParts` (func), `encodeDense` (func)
- `VectorHit`: `let score: Float64`
- `VectorMath`: `cosine` (func)

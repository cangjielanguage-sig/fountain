/*
Copyright (c) 2026 WuJingrun（吴京润）

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/
package fountain::f_hydra

import std.collection.*
import std.convert.*
import std.time.DateTime

import fountain::f_store.Store

/**
 * 基于 `f_store` 的向量实现（v0.5）。
 *
 * 布局（前缀 `h:` 与业务库隔离，详见 `fhydra/doc/fhydra-design.md` §1.3/§1.4）：
 * ```
 * h:{collection}:d:{id}          payload JSON
 * h:{collection}:v:d:{id}        dense（f32 小端）
 * h:{collection}:v:s:{id}        sparse（`token:weight,...`）
 * h:{collection}:v:c:{id}:{p}    colbert 分片（f32 小端，每片 ≤64KB）
 * h:{collection}:i:t:{tok}:{id}  稀疏倒排
 * h:{collection}:m:ivf            IVF 配置
 * h:{collection}:m:cent:{i}       IVF 簇心
 * h:{collection}:i:c:{i}:{id}     IVF 桶成员
 * h:{collection}:i:r:{id}         IVF 反向指针
 * h:{collection}:m:ttl            集合 TTL（epoch 秒）
 * h:{collection}:r:{id}           就绪标记（两阶段写的最后一步）
 * ```
 *
 * 写入顺序：payload → dense → sparse → colbert 分片 → 倒排 → **ready**。
 * 读路径一律先校验 `ready`，未就绪的半成品对查询不可见；启动时可调 `recover()`
 * 清理崩溃遗留。
 */
public class FStoreVectorStore <: VectorStore {
    private let store: Store

    public init(path: String) {
        this.store = Store(path)
    }

    public init(store: Store) {
        this.store = store
    }

    public func upsert(collection: String, record: VectorRecord): Unit {
        // 登记集合：批量重建倒排时要能枚举出所有集合
        store.add(collectionKey(collection).toArray(), [1u8])
        // 覆盖写：先清掉旧稀疏倒排、旧 colbert 分片与旧过滤索引，否则残留
        deletePostings(collection, record.id)
        deleteColbertParts(collection, record.id)
        deleteFilterEntries(collection, record.id)

        store.add(payloadKey(collection, record.id).toArray(), record.payload.toArray())
        store.add(denseKey(collection, record.id).toArray(), VectorCodec.encodeDense(record.dense))
        // 方案 C：命名 dense 字段（title/content…）各自独立存储与检索
        var names = ''
        for((name, vector) in record.vectors){
            store.add(fieldKey(collection, name, record.id).toArray(),
                      VectorCodec.encodeDense(vector))
            if(!names.isEmpty()){
                names += ','
            }
            names += name
        }
        if(!names.isEmpty()){
            store.add(fieldMetaKey(collection, record.id).toArray(), names.toArray())
        }
        store.add(timeKey(collection, record.id).toArray(), record.saveTime.toString().toArray())
        store.add(sparseKey(collection, record.id).toArray(), encodeSparse(record.sparse).toArray())
        let parts = VectorCodec.encodeColbertParts(record.colbert)
        for(index in 0..parts.size){
            store.add(colbertPartKey(collection, record.id, index).toArray(), parts[index])
        }
        for((token, weight) in record.sparse){
            store.add(postingKey(collection, token, record.id).toArray(), weight.toString().toArray())
        }
        store.add(readyKey(collection, record.id).toArray(), [1u8])
        writeFilterEntries(collection, record)
        // 索引已存在时增量挂桶；未建索引则什么都不做（检索走暴力扫描）
        ivf(collection).record(record.id, record.dense)
        ()
    }

    public func get(collection: String, id: String): ?VectorRecord {
        if(expired(collection) || !isReady(collection, id)){
            return None
        }
        match(store.get(payloadKey(collection, id).toArray())){
            case Some(bytes) =>
                let dense = match(store.get(denseKey(collection, id).toArray())){
                    case Some(raw) => VectorCodec.decodeDense(raw)
                    case None => Array<Float64>()
                }
                let sparse = match(store.get(sparseKey(collection, id).toArray())){
                    case Some(raw) => decodeSparse(String.fromUtf8(raw))
                    case None => HashMap<Int64, Float64>()
                }
                let vectors = HashMap<String, Array<Float64>>()
                match(store.get(fieldMetaKey(collection, id).toArray())){
                    case Some(raw) =>
                        for(name in String.fromUtf8(raw).split(',')){
                            if(name.isEmpty()){
                                continue
                            }
                            match(store.get(fieldKey(collection, name, id).toArray())){
                                case Some(field) => vectors[name] = VectorCodec.decodeDense(field)
                                case None => ()
                            }
                        }
                    case None => ()
                }
                let saveTime = match(store.get(timeKey(collection, id).toArray())){
                    case Some(raw) => Int64.tryParse(String.fromUtf8(raw)) ?? 0
                    case None => 0
                }
                Some(VectorRecord(id, String.fromUtf8(bytes), dense,
                                  sparse: sparse, colbert: readColbert(collection, id),
                                  vectors: vectors, filters: readFilters(collection, id),
                                  saveTime: saveTime))
            case None => None
        }
    }

    public func remove(collection: String, id: String): Bool {
        let existed = store.contains(payloadKey(collection, id).toArray())
        ivf(collection).unrecord(id)
        deletePostings(collection, id)
        deleteColbertParts(collection, id)
        deleteFilterEntries(collection, id)
        deleteFieldVectors(collection, id)
        store.remove(payloadKey(collection, id).toArray())
        store.remove(denseKey(collection, id).toArray())
        store.remove(sparseKey(collection, id).toArray())
        store.remove(readyKey(collection, id).toArray())
        store.remove(timeKey(collection, id).toArray())
        existed
    }

    public func searchDense(query: VectorQuery): ArrayList<VectorHit> {
        searchDenseField(query, 'dense')
    }

    public func searchDenseField(query: VectorQuery, field: String): ArrayList<VectorHit> {
        if(query.limit <= 0 || query.dense.isEmpty() || expired(query.collection)){
            return ArrayList<VectorHit>()
        }
        let allowed = allowedIds(query.collection, query.filters)
        if(field == 'dense'){
            // 1. IVF 候选（未建索引时为空；IVF 只建在默认 dense 上）
            let candidates = ivf(query.collection).candidates(query.dense)
            let fromIndex = scoreIds(query, candidates, allowed)
            if(Int64(fromIndex.size) >= query.limit){
                return finalize(fromIndex, query.limit)
            }
        }
        // 2. 候选不足 / 命名向量 / 未建索引：全量扫描（IVF 是优化，不牺牲召回）
        finalize(bruteForceField(query, allowed, field), query.limit)
    }

    public func buildIndex(collection: String, clusters!: Int64): Int64 {
        ivf(collection).build(clusters)
    }

    /** 便捷重载：簇数交给实现按 √n 估算 */
    public func buildIndex(collection: String): Int64 {
        buildIndex(collection, clusters: 0)
    }

    public func indexClusters(collection: String): Int64 {
        ivf(collection).clusters()
    }

    private func ivf(collection: String): IvfIndex {
        IvfIndex(store, collection)
    }

    private func bruteForceField(query: VectorQuery, allowed: ?HashMap<String, Bool>,
                                 field: String): ArrayList<VectorHit> {
        let hits = ArrayList<VectorHit>()
        let prefix = if(field == 'dense'){ densePrefix(query.collection) }
                     else { fieldPrefix(query.collection, field) }
        for((key, value) in store.prefix(prefix.toArray())){
            let text = String.fromUtf8(key)
            let id = text[Int64(prefix.size)..Int64(text.size)]
            if(!isReady(query.collection, id) || !permitted(allowed, id)){
                continue
            }
            let dense = VectorCodec.decodeDense(value)
            if(dense.size != query.dense.size){
                continue
            }
            hits.add(VectorHit(id, payloadOf(query.collection, id), VectorMath.cosine(query.dense, dense)))
        }
        hits
    }

    private func scoreIds(query: VectorQuery, ids: ArrayList<String>, allowed: ?HashMap<String, Bool>): ArrayList<VectorHit> {
        let hits = ArrayList<VectorHit>()
        for(id in ids){
            if(!isReady(query.collection, id) || !permitted(allowed, id)){
                continue
            }
            match(store.get(denseKey(query.collection, id).toArray())){
                case Some(bytes) =>
                    let dense = VectorCodec.decodeDense(bytes)
                    if(dense.size != query.dense.size){
                        continue
                    }
                    hits.add(VectorHit(id, payloadOf(query.collection, id),
                                       VectorMath.cosine(query.dense, dense)))
                case None => ()
            }
        }
        hits
    }

    private func payloadOf(collection: String, id: String): String {
        match(store.get(payloadKey(collection, id).toArray())){
            case Some(bytes) => String.fromUtf8(bytes)
            case None => ''
        }
    }

    private func finalize(hits: ArrayList<VectorHit>, limit: Int64): ArrayList<VectorHit> {
        sortDesc(hits)
        let limited = ArrayList<VectorHit>()
        for(index in 0..hits.size){
            if(Int64(index) >= limit){
                break
            }
            limited.add(hits[index])
        }
        limited
    }

    public func searchSparse(query: SparseQuery): ArrayList<VectorHit> {
        let hits = ArrayList<VectorHit>()
        if(query.limit <= 0 || query.tokens.isEmpty() || expired(query.collection)){
            return hits
        }
        let allowed = allowedIds(query.collection, query.filters)
        let scores = HashMap<String, Float64>()
        for((token, queryWeight) in query.tokens){
            let prefix = postingPrefix(query.collection, token)
            for((key, value) in store.prefix(prefix.toArray())){
                let text = String.fromUtf8(key)
                let id = text[Int64(prefix.size)..Int64(text.size)]
                let weight = Float64.parse(String.fromUtf8(value))
                let current = scores.get(id) ?? 0.0f64
                scores[id] = current + queryWeight * weight
            }
        }
        for((id, score) in scores){
            if(!isReady(query.collection, id) || !permitted(allowed, id)){
                continue
            }
            hits.add(VectorHit(id, payloadOf(query.collection, id), score))
        }
        sortDesc(hits)
        let limited = ArrayList<VectorHit>()
        for(index in 0..hits.size){
            if(Int64(index) >= query.limit){
                break
            }
            limited.add(hits[index])
        }
        limited
    }

    public func rerank(collection: String, ids: ArrayList<String>,
                       queryColbert: Array<Array<Float64>>): ArrayList<VectorHit> {
        let hits = ArrayList<VectorHit>()
        if(ids.isEmpty() || queryColbert.isEmpty() || expired(collection)){
            return hits
        }
        for(id in ids){
            if(!isReady(collection, id)){
                continue
            }
            hits.add(VectorHit(id, payloadOf(collection, id),
                               maxSim(queryColbert, readColbert(collection, id))))
        }
        sortDesc(hits)
        hits
    }

    public func count(collection: String): Int64 {
        if(expired(collection)){
            return 0
        }
        var total: Int64 = 0
        let prefix = payloadPrefix(collection)
        for((key, _) in store.prefix(prefix.toArray())){
            let text = String.fromUtf8(key)
            let id = text[Int64(prefix.size)..Int64(text.size)]
            if(isReady(collection, id)){
                total++
            }
        }
        total
    }

    // ---- v0.5 两阶段写 / TTL ----

    public func recover(collection: String): Int64 {
        if(expired(collection)){
            return purgeExpired(collection)
        }
        let ids = collectIds(collection)
        var purged: Int64 = 0
        for(id in ids){
            let hasPayload = store.contains(payloadKey(collection, id).toArray())
            if(!hasPayload || !isReady(collection, id)){
                purgeRecord(collection, id)
                purged++
            }
        }
        purged
    }

    public func setTtl(collection: String, seconds: Int64): Unit {
        if(seconds < 0){
            store.remove(ttlKey(collection).toArray())
            return
        }
        let now = DateTime.now().toUnixTimeStamp().toSeconds()
        store.add(ttlKey(collection).toArray(), (now + seconds).toString().toArray())
        ()
    }

    public func ttlOf(collection: String): Int64 {
        match(store.get(ttlKey(collection).toArray())){
            case Some(bytes) => Int64.tryParse(String.fromUtf8(bytes)) ?? 0
            case None => 0
        }
    }

    public func ids(collection: String, offset: Int64, limit: Int64): ArrayList<String> {
        let result = ArrayList<String>()
        if(limit <= 0 || expired(collection)){
            return result
        }
        let all = ArrayList<String>()
        let prefix = payloadPrefix(collection)
        for((key, _) in store.prefix(prefix.toArray())){
            let text = String.fromUtf8(key)
            let id = text[Int64(prefix.size)..Int64(text.size)]
            if(isReady(collection, id)){
                all.add(id)
            }
        }
        // 按 (saveTime, id) 升序：分页稳定且与业务时间一致
        for(index in 1..all.size){
            let current = all[index]
            var position = index - 1
            while(position >= 0 && earlier(collection, current, all[position])){
                all[position + 1] = all[position]
                position--
            }
            all[position + 1] = current
        }
        var index = offset
        while(index < Int64(all.size) && Int64(result.size) < limit){
            result.add(all[index])
            index++
        }
        result
    }

    /**
     * 按元数据过滤分页：走 `filterKey` 倒排索引，代价与命中数成正比，
     * 不做「翻页取全量再过滤」。多字段之间是 AND，单字段多值（`a,b`）是 OR。
     */
    public func idsFiltered(collection: String, filters: HashMap<String, String>,
                            offset: Int64, limit: Int64): ArrayList<String> {
        let result = ArrayList<String>()
        if(limit <= 0 || expired(collection)){
            return result
        }
        if(filters.isEmpty()){
            return ids(collection, offset, limit)
        }
        var intersection: ?HashMap<String, Bool> = None
        for((field, value) in filters){
            let hits = idsWith(collection, field, value)
            intersection = match(intersection){
                case Some(current) =>
                    let narrowed = HashMap<String, Bool>()
                    for((id, _) in current){
                        if(hits.contains(id)){
                            narrowed[id] = true
                        }
                    }
                    Some(narrowed)
                case None => Some(hits)
            }
        }
        let allowed = match(intersection){
            case Some(value) => value
            case None => HashMap<String, Bool>()
        }
        let all = ArrayList<String>()
        for((id, _) in allowed){
            if(isReady(collection, id)){
                all.add(id)
            }
        }
        // 与 ids 一致：按 (saveTime, id) 升序，分页稳定
        for(index in 1..all.size){
            let current = all[index]
            var position = index - 1
            while(position >= 0 && earlier(collection, current, all[position])){
                all[position + 1] = all[position]
                position--
            }
            all[position + 1] = current
        }
        var index = offset
        while(index < Int64(all.size) && Int64(result.size) < limit){
            result.add(all[index])
            index++
        }
        result
    }

    public func exportTo(collection: String, target: VectorStore, targetCollection: String): Int64 {
        var exported: Int64 = 0
        var offset: Int64 = 0
        let batch: Int64 = 100
        while(true){
            let page = ids(collection, offset, batch)
            if(page.isEmpty()){
                break
            }
            for(id in page){
                match(get(collection, id)){
                    case Some(record) =>
                        target.upsert(targetCollection, record)
                        exported++
                    case None => ()
                }
            }
            if(Int64(page.size) < batch){
                break
            }
            offset += batch
        }
        exported
    }

    public func purgeExpired(collection: String): Int64 {
        if(!expired(collection)){
            return 0
        }
        let prefix = 'h:${collection}:'
        let keys = ArrayList<String>()
        for((key, _) in store.prefix(prefix.toArray())){
            keys.add(String.fromUtf8(key))
        }
        for(key in keys){
            store.remove(key.toArray())
        }
        Int64(keys.size)
    }

    public func close(): Unit {
        store.close()
    }

    // ---- v0.5.1 过滤索引（白名单：kind / save_day / tags） ----

    /** 默认参与倒排的字段；可用 `setFilterFields` 覆盖（hydration 侧按部署配置注入） */
    public static let DEFAULT_FILTER_FIELDS = ['kind', 'save_day', 'tags']

    /** 持久化「上次生效的白名单」，用于启动时发现变更并自动重建 */
    private static let CONFIG_KEY = 'h:__sys:filterFields'
    /** 集合登记表：`hc:{collection}` = 1，用于枚举集合（集合名本身含 `:`，不能靠 key 前缀切） */
    private static let COLLECTION_PREFIX = 'hc:'
    /**
     * `filterMetaKey` 内的分隔符：`\u0001` 分隔字段与值、`\u0002` 分隔条目。
     *
     * 用控制字符而不是 `;` / `=`：值里出现这些符号时旧格式会把记录拆坏，
     * 而且和 `f_store` 其它键的编码习惯保持一致。
     */
    private static let META_PAIR = String.fromUtf8([1u8])
    private static let META_ENTRY = String.fromUtf8([2u8])

    /** 当前白名单（小写、去重、保持配置顺序） */
    private var indexedFields = ArrayList<String>(DEFAULT_FILTER_FIELDS)

    public func filterFields(): Array<String> {
        let result = ArrayList<String>()
        for(field in indexedFields){
            result.add(field)
        }
        result.toArray()
    }

    /**
     * 覆盖过滤字段白名单。
     *
     * 只影响**之后写入**的记录；已存在的记录需要 `rebuildFilterEntries` 重建索引。
     * 传空数组直接拒绝——白名单为空意味着所有过滤查询都会静默返回空，比报错更难排查。
     */
    public func setFilterFields(fields: Array<String>): Unit {
        let normalized = ArrayList<String>()
        for(item in fields){
            let field = item.trimAscii().toAsciiLower()
            if(field.isEmpty()){
                continue
            }
            if(!normalized.contains(field)){
                normalized.add(field)
            }
        }
        if(normalized.isEmpty()){
            throw IllegalArgumentException('filter fields must not be empty')
        }
        indexedFields = normalized
    }

    /**
     * 按当前白名单重建某集合已有记录的过滤索引，返回重建条数。
     *
     * 白名单增删字段后必须调用，否则旧记录在新字段上没有倒排项，查询会「查不到但也不报错」。
     */
    /**
     * 应用白名单：写入生效 + 与持久化的上次配置比对，变了就重建全部集合的倒排。
     *
     * @return 重建的记录条数（配置未变时为 0）
     */
    public func applyFilterFields(fields: Array<String>, rebuild!: Bool = true): Int64 {
        setFilterFields(fields)
        if(!rebuild){
            persistFilterFields(filterFields())
            return 0
        }
        if(sameFields(storedFilterFields(), filterFields())){
            return 0
        }
        let rebuilt = rebuildAllFilterEntries()
        persistFilterFields(filterFields())
        rebuilt
    }

    /** 上次持久化的白名单（空数组表示还没记录过） */
    public func storedFilterFields(): Array<String> {
        let result = ArrayList<String>()
        match(store.get(CONFIG_KEY.toArray())){
            case Some(bytes) =>
                for(item in String.fromUtf8(bytes).split(',')){
                    let field = item.trimAscii()
                    if(!field.isEmpty()){
                        result.add(field)
                    }
                }
            case None => ()
        }
        result.toArray()
    }

    /** 所有出现过的集合名（写入时登记，供批量重建倒排） */
    public func collections(): Array<String> {
        let result = ArrayList<String>()
        for((key, _) in store.prefix(COLLECTION_PREFIX.toArray())){
            let name = String.fromUtf8(key)
            if(name.size > COLLECTION_PREFIX.size){
                result.add(name[COLLECTION_PREFIX.size..])
            }
        }
        result.toArray()
    }

    /** 按当前白名单重建所有集合的倒排，返回重建条数 */
    public func rebuildAllFilterEntries(): Int64 {
        var rebuilt: Int64 = 0
        for(collection in collections()){
            rebuilt += rebuildFilterEntries(collection)
        }
        rebuilt
    }

    private func persistFilterFields(fields: Array<String>): Unit {
        var text = ''
        for(field in fields){
            if(!text.isEmpty()){
                text += ','
            }
            text += field
        }
        store.add(CONFIG_KEY.toArray(), text.toArray())
        ()
    }

    private static func sameFields(left: Array<String>, right: Array<String>): Bool {
        if(left.size != right.size){
            return false
        }
        for(field in left){
            var found = false
            for(other in right){
                if(field == other){
                    found = true
                }
            }
            if(!found){
                return false
            }
        }
        true
    }

    public func rebuildFilterEntries(collection: String): Int64 {
        var rebuilt: Int64 = 0
        var offset: Int64 = 0
        let batch: Int64 = 100
        while(true){
            let page = ids(collection, offset, batch)
            if(page.isEmpty()){
                break
            }
            for(id in page){
                match(get(collection, id)){
                    case Some(record) =>
                        deleteFilterEntries(collection, id)
                        writeFilterEntries(collection, record)
                        rebuilt++
                    case None => ()
                }
            }
            if(Int64(page.size) < batch){
                break
            }
            offset += batch
        }
        rebuilt
    }

    private func filterable(field: String): Bool {
        indexedFields.contains(field)
    }

    /** 读回元数据：`get` 必须把 `filters` 还原，否则读到记录就丢了过滤条件 */
    private func readFilters(collection: String, id: String): HashMap<String, String> {
        let filters = HashMap<String, String>()
        match(store.get(filterMetaKey(collection, id).toArray())){
            case Some(bytes) =>
                for(pair in String.fromUtf8(bytes).split(META_ENTRY)){
                    if(pair.isEmpty()){
                        continue
                    }
                    let parts = pair.split(META_PAIR)
                    if(parts.size >= 2){
                        filters[parts[0]] = parts[1]
                    }
                }
            case None => ()
        }
        filters
    }

    /**
     * 元数据落两处：
     * - `filterMetaKey` 保存**全部** filters（原样，供 `get` 读回、供白名单变更后重建索引）；
     * - `filterKey` 只给白名单内的字段建倒排（查询用）。
     *
     * 早期版本只把白名单字段写进 meta，导致换了白名单后旧记录无从重建——这是必须修掉的。
     */
    private func writeFilterEntries(collection: String, record: VectorRecord): Unit {
        var meta = ''
        for((field, value) in record.filters){
            if(!meta.isEmpty()){
                meta += META_ENTRY
            }
            meta += '${field}${META_PAIR}${value}'
            if(!filterable(field)){
                continue
            }
            for(tag in value.split(',')){
                let item = tag.trimAscii()
                if(item.isEmpty() || item.contains(':')){
                    continue
                }
                store.add(filterKey(collection, field, item, record.id).toArray(), [0u8])
            }
        }
        if(!meta.isEmpty()){
            store.add(filterMetaKey(collection, record.id).toArray(), meta.toArray())
        }
        ()
    }

    private func deleteFilterEntries(collection: String, id: String): Unit {
        match(store.get(filterMetaKey(collection, id).toArray())){
            case Some(bytes) =>
                for(pair in String.fromUtf8(bytes).split(META_ENTRY)){
                    if(pair.isEmpty()){
                        continue
                    }
                    let parts = pair.split(META_PAIR)
                    if(parts.size != 2){
                        continue
                    }
                    for(tag in parts[1].split(',')){
                        let item = tag.trimAscii()
                        if(item.isEmpty() || item.contains(':')){
                            continue
                        }
                        store.remove(filterKey(collection, parts[0], item, id).toArray())
                    }
                }
                store.remove(filterMetaKey(collection, id).toArray())
            case None => ()
        }
    }

    /**
     * 计算满足全部过滤条件的 id 集合（AND）；`None` 表示不过滤。
     * 未在白名单里的字段没有索引，命中集合直接为空——明确不匹配，而不是忽略条件。
     */
    private func allowedIds(collection: String, filters: HashMap<String, String>): ?HashMap<String, Bool> {
        if(filters.isEmpty()){
            return None
        }
        var allowed: ?HashMap<String, Bool> = None
        for((field, value) in filters){
            if(!filterable(field)){
                return Some(HashMap<String, Bool>())
            }
            let ids = idsWith(collection, field, value)
            allowed = match(allowed){
                case Some(current) => intersection(current, ids)
                case None => ids
            }
        }
        allowed
    }

    /** 同字段多值（`tags=a,b`）是 OR；跨字段在 `allowedIds` 里做 AND */
    private func idsWith(collection: String, field: String, value: String): HashMap<String, Bool> {
        let result = HashMap<String, Bool>()
        for(tag in value.split(',')){
            let item = tag.trimAscii()
            if(item.isEmpty()){
                continue
            }
            let prefix = filterPrefix(collection, field, item)
            for((key, _) in store.prefix(prefix.toArray())){
                let text = String.fromUtf8(key)
                result[text[Int64(prefix.size)..Int64(text.size)]] = true
            }
        }
        result
    }

    private static func intersection(a: HashMap<String, Bool>, b: HashMap<String, Bool>): HashMap<String, Bool> {
        let result = HashMap<String, Bool>()
        for((id, _) in a){
            if(b.contains(id)){
                result[id] = true
            }
        }
        result
    }

    private static func permitted(allowed: ?HashMap<String, Bool>, id: String): Bool {
        match(allowed){
            case Some(ids) => ids.contains(id)
            case None => true
        }
    }

    private static func filterPrefix(collection: String, field: String, value: String): String {
        'h:${collection}:f:${field}:${value}:'
    }

    private static func filterKey(collection: String, field: String, value: String, id: String): String {
        'h:${collection}:f:${field}:${value}:${id}'
    }

    private static func collectionKey(collection: String): String {
        '${COLLECTION_PREFIX}${collection}'
    }

    private static func filterMetaKey(collection: String, id: String): String {
        'h:${collection}:fl:${id}'
    }

    // ---- v0.5 helpers ----

    private func isReady(collection: String, id: String): Bool {
        store.contains(readyKey(collection, id).toArray())
    }

    private func expired(collection: String): Bool {
        let deadline = ttlOf(collection)
        if(deadline <= 0){
            return false
        }
        DateTime.now().toUnixTimeStamp().toSeconds() >= deadline
    }

    /** 收集 payload 与 dense 两类前缀下的全部 id（可能互为孤儿） */
    private func collectIds(collection: String): ArrayList<String> {
        let ids = ArrayList<String>()
        let seen = HashMap<String, Bool>()
        let payloads = payloadPrefix(collection)
        for((key, _) in store.prefix(payloads.toArray())){
            let text = String.fromUtf8(key)
            let id = text[Int64(payloads.size)..Int64(text.size)]
            if(!seen.contains(id)){
                seen[id] = true
                ids.add(id)
            }
        }
        let dense = densePrefix(collection)
        for((key, _) in store.prefix(dense.toArray())){
            let text = String.fromUtf8(key)
            let id = text[Int64(dense.size)..Int64(text.size)]
            if(!seen.contains(id)){
                seen[id] = true
                ids.add(id)
            }
        }
        ids
    }

    private func purgeRecord(collection: String, id: String): Unit {
        ivf(collection).unrecord(id)
        deletePostings(collection, id)
        deleteColbertParts(collection, id)
        deleteFilterEntries(collection, id)
        deleteFieldVectors(collection, id)
        store.remove(payloadKey(collection, id).toArray())
        store.remove(denseKey(collection, id).toArray())
        store.remove(sparseKey(collection, id).toArray())
        store.remove(readyKey(collection, id).toArray())
        store.remove(timeKey(collection, id).toArray())
        ()
    }

    /** 命名 dense 字段：读取 `vf:{id}` 名单逐个删 */
    private func deleteFieldVectors(collection: String, id: String): Unit {
        match(store.get(fieldMetaKey(collection, id).toArray())){
            case Some(raw) =>
                for(name in String.fromUtf8(raw).split(',')){
                    if(!name.isEmpty()){
                        store.remove(fieldKey(collection, name, id).toArray())
                    }
                }
                store.remove(fieldMetaKey(collection, id).toArray())
            case None => ()
        }
    }

    /** (saveTime, id) 升序：saveTime 相同再比 id */
    private func earlier(collection: String, a: String, b: String): Bool {
        let timeA = saveTimeOf(collection, a)
        let timeB = saveTimeOf(collection, b)
        if(timeA != timeB){
            return timeA < timeB
        }
        a < b
    }

    private func saveTimeOf(collection: String, id: String): Int64 {
        match(store.get(timeKey(collection, id).toArray())){
            case Some(raw) => Int64.tryParse(String.fromUtf8(raw)) ?? 0
            case None => 0
        }
    }

    // ---- keys ----

    private static func payloadPrefix(collection: String): String {
        'h:${collection}:d:'
    }

    private static func densePrefix(collection: String): String {
        'h:${collection}:v:d:'
    }

    private static func payloadKey(collection: String, id: String): String {
        'h:${collection}:d:${id}'
    }

    private static func denseKey(collection: String, id: String): String {
        'h:${collection}:v:d:${id}'
    }

    private static func sparseKey(collection: String, id: String): String {
        'h:${collection}:v:s:${id}'
    }

    private static func readyKey(collection: String, id: String): String {
        'h:${collection}:r:${id}'
    }

    /** 命名 dense 字段（方案 C）：`v:f:{name}:{id}`，名单存 `vf:{id}` */
    private static func fieldPrefix(collection: String, name: String): String {
        'h:${collection}:v:f:${name}:'
    }

    private static func fieldKey(collection: String, name: String, id: String): String {
        'h:${collection}:v:f:${name}:${id}'
    }

    private static func fieldMetaKey(collection: String, id: String): String {
        'h:${collection}:vf:${id}'
    }

    /** 业务时间（epoch 秒），`ids` 排序用 */
    private static func timeKey(collection: String, id: String): String {
        'h:${collection}:t:${id}'
    }

    private static func ttlKey(collection: String): String {
        'h:${collection}:m:ttl'
    }

    private static func postingPrefix(collection: String, token: Int64): String {
        'h:${collection}:i:t:${token}:'
    }

    private static func postingKey(collection: String, token: Int64, id: String): String {
        'h:${collection}:i:t:${token}:${id}'
    }

    /** colbert 分片：`h:{c}:v:c:{id}:{part}`，每片 ≤ 64KB */
    private static func colbertPartPrefix(collection: String, id: String): String {
        'h:${collection}:v:c:${id}:'
    }

    private static func colbertPartKey(collection: String, id: String, part: Int64): String {
        'h:${collection}:v:c:${id}:${part}'
    }

    private func deleteColbertParts(collection: String, id: String): Unit {
        let prefix = colbertPartPrefix(collection, id)
        let keys = ArrayList<String>()
        for((key, _) in store.prefix(prefix.toArray())){
            keys.add(String.fromUtf8(key))
        }
        for(key in keys){
            store.remove(key.toArray())
        }
    }

    private func readColbert(collection: String, id: String): Array<Array<Float64>> {
        let prefix = colbertPartPrefix(collection, id)
        let parts = ArrayList<String>()
        for((key, _) in store.prefix(prefix.toArray())){
            parts.add(String.fromUtf8(key))
        }
        if(parts.isEmpty()){
            return Array<Array<Float64>>()
        }
        // 键是 `...:{part}`，按 part 数字排序（part 数量很少，插入排序足够）
        for(index in 1..parts.size){
            let current = parts[index]
            var position = index - 1
            while(position >= 0 && partOf(parts[position], prefix) > partOf(current, prefix)){
                parts[position + 1] = parts[position]
                position--
            }
            parts[position + 1] = current
        }
        let rows = ArrayList<Array<Float64>>()
        for(key in parts){
            match(store.get(key.toArray())){
                case Some(bytes) =>
                    for(row in VectorCodec.decodeColbert(bytes)){
                        rows.add(row)
                    }
                case None => ()
            }
        }
        rows.toArray()
    }

    private static func partOf(key: String, prefix: String): Int64 {
        let suffix = key[Int64(prefix.size)..Int64(key.size)]
        Int64.tryParse(suffix) ?? 0
    }

    /** 覆盖写/删除前清掉旧倒排，避免旧 token 残留 */
    private func deletePostings(collection: String, id: String): Unit {
        match(store.get(sparseKey(collection, id).toArray())){
            case Some(bytes) =>
                let tokens = decodeSparse(String.fromUtf8(bytes))
                for((token, _) in tokens){
                    store.remove(postingKey(collection, token, id).toArray())
                }
            case None => ()
        }
    }

    // ---- codec（dense/colbert 走 VectorCodec 的 f32 二进制；sparse 保持文本） ----

    static func encodeSparse(tokens: HashMap<Int64, Float64>): String {
        var text = ''
        for((token, weight) in tokens){
            if(!text.isEmpty()){
                text += ','
            }
            text += '${token}:${weight}'
        }
        text
    }

    static func decodeSparse(text: String): HashMap<Int64, Float64> {
        let tokens = HashMap<Int64, Float64>()
        if(text.isEmpty()){
            return tokens
        }
        for(part in text.split(',')){
            let item = part.trimAscii()
            if(item.isEmpty()){
                continue
            }
            let pair = item.split(':')
            if(pair.size == 2){
                tokens[Int64.parse(pair[0])] = Float64.parse(pair[1])
            }
        }
        tokens
    }

    // ---- math ----

    /**
     * ColBERT max-sim：查询每个 token 在文档 token 里取最大余弦，再对查询 token 求平均。
     * 文档没有 colbert（空）时记 0，仍返回该候选（不静默丢弃）。
     */
    static func maxSim(query: Array<Array<Float64>>, doc: Array<Array<Float64>>): Float64 {
        if(query.isEmpty() || doc.isEmpty()){
            return 0.0f64
        }
        var total: Float64 = 0.0f64
        for(q in query){
            var best: Float64 = -1.0f64
            for(d in doc){
                let score = VectorMath.cosine(q, d)
                if(score > best){
                    best = score
                }
            }
            total += best
        }
        total / Float64(query.size)
    }

    private static func sortDesc(hits: ArrayList<VectorHit>): Unit {
        for(index in 1..hits.size){
            let current = hits[index]
            var position = index - 1
            while(position >= 0 && hits[position].score < current.score){
                hits[position + 1] = hits[position]
                position--
            }
            hits[position + 1] = current
        }
    }
}

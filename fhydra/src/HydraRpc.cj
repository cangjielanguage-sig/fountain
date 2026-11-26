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
package fountain::fhydra

import std.collection.*

import fountain::f_data.*
import fountain::f_hydra.*
import fountain::f_jsonrpc.*
import fountain::f_jsonrpc.base.JsonRpcException
import fountain::f_jsonrpc.macros.*

/**
 * f_hydra 的 JSON-RPC 门面：namespace = `hydra`。
 *
 * 复合结果以 **JSON 字符串** 返回（`{"hits":[...]}`），避免在服务端做二次序列化；
 * 标量结果直接用 `Bool` / `Int64`。
 */
@JsonRpc[namespace: hydra]
public class HydraRpc {
    private static let store = FStoreVectorStore(HydraConfig.dataPath())
    private static let BAD_PARAMS: Int64 = -32602

    public init() {
    }

    /**
     * 启动时装配过滤字段白名单（`hydra_filterFields`）。
     *
     * 只影响新写入的记录；已有数据要换白名单时，需另调
     * `FStoreVectorStore.rebuildFilterEntries(collection)` 重建倒排。
     */
    public static func configure(): Unit {
        // 与上次持久化的白名单比对：变了就重建全部集合的倒排（返回重建条数，这里不关心）
        let rebuilt = store.applyFilterFields(HydraConfig.filterFields())
        let _ = rebuilt
    }

    @JsonRpcMeta['健康检查', '1s']
    public func health(): String {
        '{"status":"ok","version":"1.3.17"}'
    }

    @JsonRpcMeta['写入一条记录', '5s']
    public func upsert(param: UpsertParam): Bool {
        HydraAuth.require()
        let dense = denseOf(param.denseB64, param.dense)
        if(dense.isEmpty() && param.titleDense.isEmpty() && param.contentDense.isEmpty()){
            throw JsonRpcException(BAD_PARAMS, 'dense/denseB64/titleDense/contentDense is required')
        }
        store.upsert(param.collection, recordOf(param.id, param.payload, dense, param))
        true
    }

    @JsonRpcMeta['批量写入（≤100 条）', '10s']
    public func upsertBatch(params: Array<UpsertParam>): Int64 {
        HydraAuth.require()
        if(params.size > 100){
            throw JsonRpcException(BAD_PARAMS, 'upsertBatch accepts at most 100 records')
        }
        var written: Int64 = 0
        for(param in params){
            let dense = denseOf(param.denseB64, param.dense)
            if(dense.isEmpty()){
                throw JsonRpcException(BAD_PARAMS, 'record ${param.id}: dense/denseB64 is required')
            }
            store.upsert(param.collection, recordOf(param.id, param.payload, dense, param))
            written++
        }
        written
    }

    @JsonRpcMeta['按 id 读取', '2s']
    public func get(param: GetParam): RecordDto {
        HydraAuth.require()
        match(store.get(param.collection, param.id)){
            case Some(record) => recordDto(record)
            case None => RecordDto()
        }
    }

    @JsonRpcMeta['删除记录', '2s']
    public func remove(param: RemoveParam): Bool {
        HydraAuth.require()
        store.remove(param.collection, param.id)
    }

    @JsonRpcMeta['dense 检索', '5s']
    public func searchDense(param: SearchParam): HitsDto {
        HydraAuth.require()
        let dense = denseOf(param.denseB64, param.dense)
        if(dense.isEmpty()){
            throw JsonRpcException(BAD_PARAMS, 'dense/denseB64 is required')
        }
        if(param.limit <= 0){
            throw JsonRpcException(BAD_PARAMS, 'limit must be positive')
        }
        let field = if(param.field.isEmpty()){ 'dense' }else{ param.field }
        let hits = store.searchDenseField(
            VectorQuery(param.collection, dense, limit: param.limit,
                        filters: filtersOf(param.kind, param.saveDay, param.tags)), field)
        hitsDto(hits)
    }

    @JsonRpcMeta['sparse 检索', '5s']
    public func searchSparse(param: SparseParam): HitsDto {
        HydraAuth.require()
        if(param.tokenIds.size != param.weights.size){
            throw JsonRpcException(BAD_PARAMS, 'tokenIds and weights must have the same length')
        }
        if(param.limit <= 0){
            throw JsonRpcException(BAD_PARAMS, 'limit must be positive')
        }
        let tokens = HashMap<Int64, Float64>()
        for(index in 0..param.tokenIds.size){
            tokens[param.tokenIds[index]] = param.weights[index]
        }
        let hits = store.searchSparse(SparseQuery(param.collection, tokens, limit: param.limit,
                                                  filters: filtersOf(param.kind, param.saveDay, param.tags)))
        hitsDto(hits)
    }

    @JsonRpcMeta['记录数', '2s']
    public func count(param: CollectionParam): Int64 {
        HydraAuth.require()
        store.count(param.collection)
    }

    @JsonRpcMeta['id 分页（可按元数据过滤）', '2s']
    public func ids(param: IdsParam): IdsDto {
        HydraAuth.require()
        let dto = IdsDto()
        // 带 filters 时走元数据倒排，不要求调用方翻页自己过滤
        let ids = if(param.filters.isEmpty()){
            store.ids(param.collection, param.offset, param.limit)
        }else{
            store.idsFiltered(param.collection, param.filters, param.offset, param.limit)
        }
        for(id in ids){
            dto.ids.add(id)
        }
        dto
    }

    @JsonRpcMeta['colbert 重排', '5s']
    public func rerank(param: RerankParam): HitsDto {
        HydraAuth.require()
        hitsDto(store.rerank(param.collection, param.ids, param.colbert))
    }

    @JsonRpcMeta['训练/重建 IVF', '60s']
    public func buildIndex(param: BuildIndexParam): Int64 {
        HydraAuth.require()
        store.buildIndex(param.collection, clusters: param.clusters)
    }

    @JsonRpcMeta['当前簇数', '1s']
    public func indexClusters(param: CollectionParam): Int64 {
        HydraAuth.require()
        store.indexClusters(param.collection)
    }

    @JsonRpcMeta['集合导出（同进程内）', '60s']
    public func export(param: ExportParam): Int64 {
        HydraAuth.require()
        if(param.targetCollection.isEmpty()){
            throw JsonRpcException(BAD_PARAMS, 'targetCollection is required')
        }
        store.exportTo(param.collection, store, param.targetCollection)
    }

    @JsonRpcMeta['重建/清理半成品', '60s']
    public func recover(param: CollectionParam): Int64 {
        HydraAuth.require()
        store.recover(param.collection)
    }

    @JsonRpcMeta['设置集合 TTL', '2s']
    public func setTtl(param: TtlParam): Bool {
        HydraAuth.require()
        store.setTtl(param.collection, param.seconds)
        true
    }

    @JsonRpcMeta['读取集合 TTL', '1s']
    public func ttl(param: CollectionParam): Int64 {
        HydraAuth.require()
        store.ttlOf(param.collection)
    }

    @JsonRpcMeta['删除过期集合', '60s']
    public func purgeExpired(param: CollectionParam): Int64 {
        HydraAuth.require()
        store.purgeExpired(param.collection)
    }

    // ---- helpers ----

    private static func recordOf(id: String, payload: String, dense: Array<Float64>,
                                 param: UpsertParam): VectorRecord {
        let vectors = HashMap<String, Array<Float64>>()
        if(!param.titleDense.isEmpty()){
            vectors['title'] = param.titleDense.toArray()
        }
        if(!param.contentDense.isEmpty()){
            vectors['content'] = param.contentDense.toArray()
        }
        let sparse = HashMap<Int64, Float64>()
        for(index in 0..param.tokenIds.size){
            if(index < param.weights.size){
                sparse[param.tokenIds[index]] = param.weights[index]
            }
        }
        VectorRecord(id, payload, dense,
                     sparse: sparse,
                     filters: filtersOf(param.kind, param.saveDay, param.tags),
                     vectors: vectors, saveTime: param.saveTime)
    }

    private static func filtersOf(kind: String, saveDay: String, tags: String): HashMap<String, String> {
        let filters = HashMap<String, String>()
        if(!kind.isEmpty()){
            filters['kind'] = kind
        }
        if(!saveDay.isEmpty()){
            filters['save_day'] = saveDay
        }
        if(!tags.isEmpty()){
            filters['tags'] = tags
        }
        filters
    }

    /** `denseB64` 优先（f32 小端原始字节），否则用数值数组 */
    private static func denseOf(encoded: String, values: Array<Float64>): Array<Float64> {
        if(!encoded.isEmpty()){
            return decodeDenseB64(encoded)
        }
        values
    }

    private static func decodeDenseB64(encoded: String): Array<Float64> {
        match(fromBase64String(encoded)){
            case Some(bytes) =>
                if(bytes.size % 4 != 0){
                    throw JsonRpcException(BAD_PARAMS, 'denseB64 length must be a multiple of 4')
                }
                let count = Int64(bytes.size) / 4
                let values = Array<Float64>(count, repeat: 0.0f64)
                for(index in 0..count){
                    let offset = index * 4
                    let bits = UInt32(bytes[offset]) |
                               (UInt32(bytes[offset + 1]) << 8) |
                               (UInt32(bytes[offset + 2]) << 16) |
                               (UInt32(bytes[offset + 3]) << 24)
                    values[index] = Float64(Float32.fromBits(bits))
                }
                values
            case None => throw JsonRpcException(BAD_PARAMS, 'denseB64 is not valid base64')
        }
    }

    private static func hitsDto(hits: ArrayList<VectorHit>): HitsDto {
        let dto = HitsDto()
        for(hit in hits){
            dto.hits.add(HitDto(hit.id, hit.payload, hit.score))
        }
        dto
    }

    private static func hitsJson(hits: ArrayList<VectorHit>): String {
        var text = '{"hits":['
        for(index in 0..hits.size){
            if(index > 0){
                text += ','
            }
            let hit = hits[index]
            text += '{"id":${jsonQuote(hit.id)},"payload":${jsonQuote(hit.payload)},"score":${hit.score}}'
        }
        text + ']}'
    }

    private static func recordDto(record: VectorRecord): RecordDto {
        let dto = RecordDto()
        dto.found = true
        dto.id = record.id
        dto.payload = record.payload
        for(value in record.dense){
            dto.dense.add(value)
        }
        match(record.vectors.get('title')){
            case Some(vector) => for(value in vector){ dto.titleDense.add(value) }
            case None => ()
        }
        match(record.vectors.get('content')){
            case Some(vector) => for(value in vector){ dto.contentDense.add(value) }
            case None => ()
        }
        for((token, weight) in record.sparse){
            dto.tokenIds.add(token)
            dto.weights.add(weight)
        }
        dto.colbert = record.colbert
        dto.saveTime = record.saveTime
        dto
    }

    private static func jsonQuote(text: String): String {
        var result = '"'
        for(byte in text.toArray()){
            let ch = UInt8(byte)
            if(ch == 34u8){
                result += '\\"'
            }else if(ch == 92u8){
                result += '\\\\'
            }else if(ch == 10u8){
                result += '\\n'
            }else if(ch == 13u8){
                result += '\\r'
            }else if(ch == 9u8){
                result += '\\t'
            }else{
                result += String.fromUtf8([ch])
            }
        }
        result + '"'
    }
}

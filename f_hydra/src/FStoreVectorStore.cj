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

import fountain::f_store.Store

/**
 * 基于 `f_store` 的向量实现（v0.1）。
 *
 * 布局（前缀 `h:` 与业务库隔离）：
 * ```
 * h:{collection}:d:{id}      payload JSON
 * h:{collection}:v:d:{id}    dense（逗号分隔的十进制，v0.2 换 f32 小端）
 * h:{collection}:v:s:{id}    sparse（`token:weight,...`）
 * h:{collection}:r:{id}      就绪标记
 * ```
 * 检索是**暴力扫描**：遍历 collection 内的 dense 前缀逐个算余弦。
 * 这是设计文档里 BruteForce 阶段，数据量上来后替换为 IVF-Flat / IVF-PQ。
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
        // 覆盖写：先清掉旧稀疏倒排与旧 colbert 分片，否则残留
        deletePostings(collection, record.id)
        deleteColbertParts(collection, record.id)

        store.add(payloadKey(collection, record.id).toArray(), record.payload.toArray())
        store.add(denseKey(collection, record.id).toArray(), VectorCodec.encodeDense(record.dense))
        store.add(sparseKey(collection, record.id).toArray(), encodeSparse(record.sparse).toArray())
        let parts = VectorCodec.encodeColbertParts(record.colbert)
        for(index in 0..parts.size){
            store.add(colbertPartKey(collection, record.id, index).toArray(), parts[index])
        }
        for((token, weight) in record.sparse){
            store.add(postingKey(collection, token, record.id).toArray(), weight.toString().toArray())
        }
        store.add(readyKey(collection, record.id).toArray(), [1u8])
        ()
    }

    public func get(collection: String, id: String): ?VectorRecord {
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
                Some(VectorRecord(id, String.fromUtf8(bytes), dense,
                                  sparse: sparse, colbert: readColbert(collection, id)))
            case None => None
        }
    }

    public func remove(collection: String, id: String): Bool {
        let existed = store.contains(payloadKey(collection, id).toArray())
        deletePostings(collection, id)
        deleteColbertParts(collection, id)
        store.remove(payloadKey(collection, id).toArray())
        store.remove(denseKey(collection, id).toArray())
        store.remove(sparseKey(collection, id).toArray())
        store.remove(readyKey(collection, id).toArray())
        existed
    }

    public func searchDense(query: VectorQuery): ArrayList<VectorHit> {
        let hits = ArrayList<VectorHit>()
        if(query.limit <= 0 || query.dense.isEmpty()){
            return hits
        }
        let prefix = densePrefix(query.collection)
        for((key, value) in store.prefix(prefix.toArray())){
            let text = String.fromUtf8(key)
            let id = text[Int64(prefix.size)..Int64(text.size)]
            let dense = VectorCodec.decodeDense(value)
            if(dense.size != query.dense.size){
                continue
            }
            let score = cosine(query.dense, dense)
            let payload = match(store.get(payloadKey(query.collection, id).toArray())){
                case Some(bytes) => String.fromUtf8(bytes)
                case None => ''
            }
            hits.add(VectorHit(id, payload, score))
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

    public func searchSparse(query: SparseQuery): ArrayList<VectorHit> {
        let hits = ArrayList<VectorHit>()
        if(query.limit <= 0 || query.tokens.isEmpty()){
            return hits
        }
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
            let payload = match(store.get(payloadKey(query.collection, id).toArray())){
                case Some(bytes) => String.fromUtf8(bytes)
                case None => ''
            }
            hits.add(VectorHit(id, payload, score))
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
        if(ids.isEmpty() || queryColbert.isEmpty()){
            return hits
        }
        for(id in ids){
            let docColbert = readColbert(collection, id)
            let payload = match(store.get(payloadKey(collection, id).toArray())){
                case Some(bytes) => String.fromUtf8(bytes)
                case None => ''
            }
            hits.add(VectorHit(id, payload, maxSim(queryColbert, docColbert)))
        }
        sortDesc(hits)
        hits
    }

    public func count(collection: String): Int64 {
        var total: Int64 = 0
        for(_ in store.prefix(payloadPrefix(collection).toArray())){
            total++
        }
        total
    }

    public func close(): Unit {
        store.close()
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

    static func cosine(a: Array<Float64>, b: Array<Float64>): Float64 {
        if(a.size != b.size || a.isEmpty()){
            return 0.0f64
        }
        var dot: Float64 = 0.0f64
        var normA: Float64 = 0.0f64
        var normB: Float64 = 0.0f64
        for(index in 0..a.size){
            dot += a[index] * b[index]
            normA += a[index] * a[index]
            normB += b[index] * b[index]
        }
        if(normA <= 0.0f64 || normB <= 0.0f64){
            return 0.0f64
        }
        dot / (sqrt(normA) * sqrt(normB))
    }

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
                let score = cosine(q, d)
                if(score > best){
                    best = score
                }
            }
            total += best
        }
        total / Float64(query.size)
    }

    private static func sqrt(value: Float64): Float64 {
        if(value <= 0.0f64){
            return 0.0f64
        }
        var guess = value
        for(_ in 0..30){
            guess = (guess + value / guess) / 2.0f64
        }
        guess
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

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

/** IVF 配置：维度与簇数 */
public class IvfConfig {
    public let dim: Int64
    public let clusters: Int64

    public init(dim: Int64, clusters: Int64) {
        this.dim = dim
        this.clusters = clusters
    }
}

/**
 * IVF-Flat 索引（v0.4）。
 *
 * 布局（`{c}` = collection）：
 * ```
 * h:{c}:m:ivf              cfg 文本 `dim,clusters`
 * h:{c}:m:cent:{i}         簇心（VectorCodec dense 二进制）
 * h:{c}:i:c:{i}:{id}       桶成员（value 空）
 * h:{c}:i:r:{id}           反向指针（所属簇），删除时用
 * ```
 *
 * 训练用确定性 k-means（初始簇心按等距抽样，迭代 10 轮），不引入随机性，便于测试复现。
 * 写入时若索引已存在，会按最近簇心增量挂桶；簇心变化后通过 `build()` 重建纠正。
 */
class IvfIndex {
    private static let MAX_ITERATIONS: Int64 = 10
    private static let DEFAULT_NPROBE: Int64 = 8

    private let store: Store
    private let collection: String

    init(store: Store, collection: String) {
        this.store = store
        this.collection = collection
    }

    public func config(): ?IvfConfig {
        match(store.get(cfgKey().toArray())){
            case Some(bytes) =>
                let parts = String.fromUtf8(bytes).split(',')
                if(parts.size != 2){
                    return None
                }
                Some(IvfConfig(Int64.parse(parts[0]), Int64.parse(parts[1])))
            case None => None
        }
    }

    public func clusters(): Int64 {
        match(config()){
            case Some(cfg) => cfg.clusters
            case None => 0
        }
    }

    /** 训练/重建，返回簇数；数据为空时清空索引并返回 0 */
    public func build(requested: Int64): Int64 {
        let items = loadVectors()
        clear()
        if(items.isEmpty()){
            return 0
        }
        let count = Int64(items.size)
        var k = if(requested > 0){ requested }else{ Int64(sqrt(Float64(count))) }
        if(k < 1){
            k = 1
        }
        if(k > count){
            k = count
        }
        let dim = items[0].vector.size
        let centroids = ArrayList<Array<Float64>>()
        for(index in 0..k){
            centroids.add(copyOf(items[Int64(index) * count / k].vector))
        }
        for(_ in 0..MAX_ITERATIONS){
            let sums = ArrayList<Array<Float64>>()
            let counts = Array<Int64>(k, repeat: 0)
            for(_ in 0..k){
                sums.add(Array<Float64>(dim, repeat: 0.0f64))
            }
            for(item in items){
                if(item.vector.size != dim){
                    continue
                }
                let cluster = nearest(centroids, item.vector)
                counts[cluster] = counts[cluster] + 1
                for(index in 0..dim){
                    sums[cluster][index] += item.vector[index]
                }
            }
            for(cluster in 0..k){
                if(counts[cluster] == 0){
                    continue
                }
                for(index in 0..dim){
                    centroids[cluster][index] = sums[cluster][index] / Float64(counts[cluster])
                }
            }
        }

        store.add(cfgKey().toArray(), '${dim},${k}'.toArray())
        for(cluster in 0..k){
            store.add(centroidKey(cluster).toArray(), VectorCodec.encodeDense(centroids[cluster]))
        }
        for(item in items){
            if(item.vector.size != dim){
                continue
            }
            let cluster = nearest(centroids, item.vector)
            store.add(bucketKey(cluster, item.id).toArray(), [0u8])
            store.add(reverseKey(item.id).toArray(), cluster.toString().toArray())
        }
        k
    }

    /** 增量挂桶：索引存在时把新向量挂到最近簇（簇心漂移由 build 纠正） */
    public func record(id: String, vector: Array<Float64>): Unit {
        match(config()){
            case Some(cfg) =>
                if(cfg.dim != vector.size){
                    return
                }
                let centroids = loadCentroids(cfg.clusters)
                if(centroids.isEmpty()){
                    return
                }
                let cluster = nearest(centroids, vector)
                store.add(bucketKey(cluster, id).toArray(), [0u8])
                store.add(reverseKey(id).toArray(), cluster.toString().toArray())
            case None => ()
        }
    }

    public func unrecord(id: String): Unit {
        match(store.get(reverseKey(id).toArray())){
            case Some(bytes) =>
                match(Int64.tryParse(String.fromUtf8(bytes))){
                    case Some(cluster) => store.remove(bucketKey(cluster, id).toArray())
                    case None => ()
                }
                store.remove(reverseKey(id).toArray())
            case None => ()
        }
    }

    /** 返回探测到的候选 id（可能为空：索引未建/维度不符） */
    public func candidates(query: Array<Float64>, nprobe!: Int64 = DEFAULT_NPROBE): ArrayList<String> {
        let ids = ArrayList<String>()
        match(config()){
            case Some(cfg) =>
                if(cfg.dim != query.size){
                    return ids
                }
                let centroids = loadCentroids(cfg.clusters)
                let scored = ArrayList<ClusterScore>()
                for(cluster in 0..centroids.size){
                    scored.add(ClusterScore(Int64(cluster),
                                            VectorMath.cosine(query, centroids[cluster])))
                }
                sortClusters(scored)
                let probes = if(nprobe < cfg.clusters){ nprobe }else{ cfg.clusters }
                let seen = HashMap<String, Bool>()
                for(index in 0..probes){
                    if(Int64(index) >= Int64(scored.size)){
                        break
                    }
                    let cluster = scored[index].cluster
                    let prefix = bucketPrefix(cluster)
                    for((key, _) in store.prefix(prefix.toArray())){
                        let text = String.fromUtf8(key)
                        let id = text[Int64(prefix.size)..Int64(text.size)]
                        if(!seen.contains(id)){
                            seen[id] = true
                            ids.add(id)
                        }
                    }
                }
            case None => ()
        }
        ids
    }

    // ---- internal ----

    private func loadVectors(): ArrayList<IndexedVector> {
        let items = ArrayList<IndexedVector>()
        let prefix = densePrefix()
        for((key, value) in store.prefix(prefix.toArray())){
            let text = String.fromUtf8(key)
            let id = text[Int64(prefix.size)..Int64(text.size)]
            let vector = VectorCodec.decodeDense(value)
            if(!vector.isEmpty()){
                items.add(IndexedVector(id, vector))
            }
        }
        items
    }

    private func loadCentroids(k: Int64): ArrayList<Array<Float64>> {
        let centroids = ArrayList<Array<Float64>>()
        for(cluster in 0..k){
            match(store.get(centroidKey(cluster).toArray())){
                case Some(bytes) => centroids.add(VectorCodec.decodeDense(bytes))
                case None => ()
            }
        }
        centroids
    }

    private func clear(): Unit {
        let prefixes = ArrayList<String>()
        prefixes.add(centroidPrefix())
        prefixes.add(bucketBasePrefix())
        prefixes.add(reversePrefix())
        for(prefix in prefixes){
            let keys = ArrayList<String>()
            for((key, _) in store.prefix(prefix.toArray())){
                keys.add(String.fromUtf8(key))
            }
            for(key in keys){
                store.remove(key.toArray())
            }
        }
        store.remove(cfgKey().toArray())
    }

    private func nearest(centroids: ArrayList<Array<Float64>>, vector: Array<Float64>): Int64 {
        var best: Int64 = 0
        var bestScore: Float64 = -2.0f64
        for(cluster in 0..centroids.size){
            let score = VectorMath.cosine(vector, centroids[cluster])
            if(score > bestScore){
                bestScore = score
                best = Int64(cluster)
            }
        }
        best
    }

    // ---- keys ----

    private func cfgKey(): String {
        'h:${collection}:m:ivf'
    }

    private func centroidPrefix(): String {
        'h:${collection}:m:cent:'
    }

    private func centroidKey(cluster: Int64): String {
        'h:${collection}:m:cent:${cluster}'
    }

    private func bucketBasePrefix(): String {
        'h:${collection}:i:c:'
    }

    private func bucketPrefix(cluster: Int64): String {
        'h:${collection}:i:c:${cluster}:'
    }

    private func bucketKey(cluster: Int64, id: String): String {
        'h:${collection}:i:c:${cluster}:${id}'
    }

    private func reversePrefix(): String {
        'h:${collection}:i:r:'
    }

    private func reverseKey(id: String): String {
        'h:${collection}:i:r:${id}'
    }

    private func densePrefix(): String {
        'h:${collection}:v:d:'
    }

    // ---- math ----

    private static func copyOf(vector: Array<Float64>): Array<Float64> {
        let copy = Array<Float64>(vector.size, repeat: 0.0f64)
        for(index in 0..vector.size){
            copy[index] = vector[index]
        }
        copy
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

    private static func sortClusters(items: ArrayList<ClusterScore>): Unit {
        for(index in 1..items.size){
            let current = items[index]
            var position = index - 1
            while(position >= 0 && items[position].score < current.score){
                items[position + 1] = items[position]
                position--
            }
            items[position + 1] = current
        }
    }
}

class IndexedVector {
    public let id: String
    public let vector: Array<Float64>

    init(id: String, vector: Array<Float64>) {
        this.id = id
        this.vector = vector
    }
}

class ClusterScore {
    public let cluster: Int64
    public let score: Float64

    init(cluster: Int64, score: Float64) {
        this.cluster = cluster
        this.score = score
    }
}

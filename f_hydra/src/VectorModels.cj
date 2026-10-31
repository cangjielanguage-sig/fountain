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

/**
 * 一条向量记录（f_hydra 只认识 collection / id / payload / 三路向量）。
 *
 * `payload` 是不透明 JSON：业务字段（标题、正文、kind…）由调用方决定，
 * f_hydra 不解析、不索引（过滤索引留到 v0.2）。
 */
public class VectorRecord {
    public let id: String
    public let payload: String
    public let dense: Array<Float64>
    public let sparse: HashMap<Int64, Float64>
    /** 多头向量（每 token 一个向量），只用于重排，不建索引 */
    public let colbert: Array<Array<Float64>>

    public init(id: String, payload: String, dense: Array<Float64>,
                sparse!: HashMap<Int64, Float64> = HashMap<Int64, Float64>(),
                colbert!: Array<Array<Float64>> = Array<Array<Float64>>()) {
        this.id = id
        this.payload = payload
        this.dense = dense
        this.sparse = sparse
        this.colbert = colbert
    }
}

/** dense 检索请求 */
public class VectorQuery {
    public let collection: String
    public let dense: Array<Float64>
    public let limit: Int64

    public init(collection: String, dense: Array<Float64>, limit!: Int64 = 10) {
        this.collection = collection
        this.dense = dense
        this.limit = limit
    }
}

/** 稀疏（词面）检索请求：`tokens` 是查询侧的 token→权重 */
public class SparseQuery {
    public let collection: String
    public let tokens: HashMap<Int64, Float64>
    public let limit: Int64

    public init(collection: String, tokens: HashMap<Int64, Float64>, limit!: Int64 = 10) {
        this.collection = collection
        this.tokens = tokens
        this.limit = limit
    }
}

/** 检索结果 */
public class VectorHit {
    public let id: String
    public let payload: String
    public let score: Float64

    public init(id: String, payload: String, score: Float64) {
        this.id = id
        this.payload = payload
        this.score = score
    }
}

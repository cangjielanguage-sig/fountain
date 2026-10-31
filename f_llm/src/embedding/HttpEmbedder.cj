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
package fountain::f_llm.embedding

import std.collection.*

import fountain::f_llm.store.*

/**
 * 向量服务一次返回的三路结果（2.x）。
 *
 * 真实实现（HTTP + JSON 解析）放在 `EmbeddingTransport` 的具体类里，
 * 这里只做维度校验与字段转换，便于用假 transport 做单测。
 */
public class EmbeddingResponse {
    public let dense: Array<Float64>
    public let sparse: HashMap<Int64, Float64>
    public let colbert: Array<Array<Float64>>

    public init(dense: Array<Float64>,
                sparse!: HashMap<Int64, Float64> = HashMap<Int64, Float64>(),
                colbert!: Array<Array<Float64>> = Array<Array<Float64>>()) {
        this.dense = dense
        this.sparse = sparse
        this.colbert = colbert
    }
}

/** 传输层抽象：负责真正的 HTTP 调用与 JSON 编解码。 */
public interface EmbeddingTransport {
    func embed(text: String): EmbeddingResponse
}

/**
 * BGE-M3 向量化实现（2.2）：
 * - dense 维度必须等于约定维度，否则抛错（不静默截断/补零）；
 * - sparse / colbert 缺失时返回空集合，由调用方决定是否降级。
 */
public class HttpEmbedder <: Embedder {
    public static const DEFAULT_DIM = 1024

    private let transport: EmbeddingTransport
    private let dim: Int64

    public init(transport: EmbeddingTransport, dim!: Int64 = DEFAULT_DIM) {
        this.transport = transport
        this.dim = dim
    }

    public func embed(text: String): Array<Float64> {
        let response = transport.embed(text)
        if(Int64(response.dense.size) != dim){
            throw IllegalStateException(
                'embedding dimension mismatch: expected ${dim}, got ${response.dense.size}')
        }
        response.dense
    }

    public func embedColbert(text: String): Array<Array<Float64>> {
        transport.embed(text).colbert
    }

    public func tokenize(text: String): HashMap<Int64, Float64> {
        transport.embed(text).sparse
    }
}

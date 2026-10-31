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
import std.convert.*

import stdx.net.tls.common.*

import fountain::f_data.*
import fountain::f_httpclient.*

import fountain::f_llm.store.*

/**
 * 本机 BGE-M3 服务的传输层（`/v1/embeddings` + `return_sparse` / `return_colbert_vecs`）。
 *
 * 响应形状（实测 2026-10-31，`/opt/bge-m3`）：
 * ```
 * data[0] = { embedding: [1024], colbert_vecs: [[1024], ...], lexical_weights: {"<tokenId>": w} }
 * ```
 * 其中 sparse 是**词频近似**（该权重目录没有 `sparse_linear.pt`），字段名与形状对齐
 * FlagEmbedding，便于以后换成真实稀疏头而不改上层。
 */
public class BgeM3Transport <: EmbeddingTransport {
    public static const DEFAULT_URL = 'http://127.0.0.1:8000/v1/embeddings'

    private let url: String

    public init(url!: String = DEFAULT_URL) {
        this.url = url
    }

    public func embed(text: String): EmbeddingResponse {
        let body = '''
{"input":["${escape(text)}"],"return_sparse":true,"return_colbert_vecs":true}
'''
        let client = HttpClient(url)
        client.header('Content-Type', 'application/json')
        client.header('Accept-Encoding', 'identity')
        var tls = TlsClientConfig()
        tls.verifyMode = CertificateVerifyMode.TrustAll
        client.tlsConfig(tls)
        resource(client){http =>
            let response = http.post(body)
            if(Int64(response.status) >= 400){
                throw IllegalStateException('bge-m3 embedding failed, status ${response.status}')
            }
            BgeM3Codec.parse(response.readEntire())
        }
    }

    private static func escape(text: String): String {
        text.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n')
    }
}

/** 把 BGE-M3 的响应 JSON 转成 `EmbeddingResponse`（可单测，不经网络）。 */
public class BgeM3Codec {
    public static func parse(body: String): EmbeddingResponse {
        let root = JsonValue.fromStr(body).asObject()
        let data = match(root.get('data')){
            case Some(value) => value.asArray().getItems()
            case None => throw IllegalStateException('bge-m3 response missing data')
        }
        if(data.isEmpty()){
            throw IllegalStateException('bge-m3 response data is empty')
        }
        let item = data[0].asObject()
        let dense = floatsOf(item.get('embedding'))

        let sparse = HashMap<Int64, Float64>()
        if(let Some(weights) <- item.get('lexical_weights')){
            for((token, weight) in weights.asObject().getFields()){
                sparse[Int64.parse(token)] = Float64.parse(weight.toString())
            }
        }

        var colbert = Array<Array<Float64>>()
        if(let Some(vectors) <- item.get('colbert_vecs')){
            let list = ArrayList<Array<Float64>>()
            for(vector in vectors.asArray().getItems()){
                list.add(floatsOf(Some(vector)))
            }
            colbert = list.toArray()
        }
        EmbeddingResponse(dense, sparse: sparse, colbert: colbert)
    }

    private static func floatsOf(value: ?JsonValue): Array<Float64> {
        let items = match(value){
            case Some(raw) => raw.asArray().getItems()
            case None => throw IllegalStateException('bge-m3 response missing embedding')
        }
        let values = Array<Float64>(items.size, repeat: 0.0f64)
        for(index in 0..items.size){
            values[index] = Float64.parse(items[index].toString())
        }
        values
    }
}

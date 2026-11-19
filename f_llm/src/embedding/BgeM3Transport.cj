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
import std.sync.*
import std.time.*

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
 * `lexical_weights` 来自官方 `sparse_linear.pt`（ReLU(h·w+b)，同 token 取最大，与
 * FlagEmbedding `_process_token_weights` 一致）；`colbert_vecs` 来自官方
 * `colbert_linear.pt` 投影后按 token 归一化。
 */
public class BgeM3Transport <: EmbeddingTransport {
    public static const DEFAULT_URL = 'http://127.0.0.1:8000/v1/embeddings'

    private let url: String
    private let timeoutMs: Int64
    private let retries: Int64

    public init(url!: String = DEFAULT_URL, timeoutMs!: Int64 = 3000, retries!: Int64 = 2) {
        this.url = url
        this.timeoutMs = timeoutMs
        this.retries = retries
    }

    /**
     * 失败重试（2 次，退避 100ms / 300ms），仍失败则抛最后一次异常。
     *
     * 超时只覆盖读/写：`stdx.net.http` 的 `ClientBuilder` 没有连接超时入口，
     * `HttpClient` 也只暴露 `readTimeout` / `writeTimeout`，因此建连阶段依赖
     * 操作系统 TCP 超时。
     */
    public func embed(text: String): EmbeddingResponse {
        if(timeoutMs > 0){
            HttpClient.globalReadTimeout(Duration.millisecond * timeoutMs)
            HttpClient.globalWriteTimeout(Duration.millisecond * timeoutMs)
        }
        var last: ?Exception = None
        for(attempt in 0..(retries + 1)){
            try{
                return postOnce(text)
            }catch(e: Exception){
                last = Some(e)
                if(attempt < retries){
                    sleep(Duration.millisecond * (100 * (attempt + 1)))
                }
            }
        }
        throw match(last){
            case Some(error) => error
            case None => IllegalStateException('bge-m3 embedding failed without exception')
        }
    }

    private func postOnce(text: String): EmbeddingResponse {
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

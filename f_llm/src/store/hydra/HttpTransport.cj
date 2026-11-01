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
package fountain::f_llm.store.hydra

import std.collection.*
import std.convert.*
import std.env.*

import stdx.net.tls.common.*

import fountain::f_data.*
import fountain::f_data.base.DataObject
import fountain::f_data.base.ObjectData
import fountain::f_data.macros.DataAssist
import fountain::f_httpclient.*

import fountain::f_hydra.*

import fountain::f_llm.store.*

/**
 * 远程 fhydra 传输：JSON-RPC over HTTP。
 *
 * 复用与 `BgeM3Transport` 相同的 `HttpClient` 用法；响应按
 * `JsonValue.fromStr(json).toData()` + `DataObject<T>.populate(data)` 解析。
 */
class HttpTransport <: HydraTransport {
    private static let KEY_HEADER = 'X-Hydra-Key'

    private let url: String
    private let secret: String

    public init(url!: String = '', secret!: String = '') {
        this.url = if(url.isEmpty()){
            getVariable('llm_hydraUrl') ?? 'http://127.0.0.1:18081/rpc'
        }else{
            url
        }
        this.secret = if(secret.isEmpty()){
            getVariable('llm_hydraSecret') ?? ''
        }else{
            secret
        }
    }

    public func upsert(collection: String, record: VectorRecord): Unit {
        var title = ''
        var content = ''
        match(record.vectors.get('title')){
            case Some(vector) => title = ',"titleDense":${numbers(vector)}'
            case None => ()
        }
        match(record.vectors.get('content')){
            case Some(vector) => content = ',"contentDense":${numbers(vector)}'
            case None => ()
        }
        let param = '{"collection":"${esc(collection)}","id":"${esc(record.id)}",'
            + '"payload":"${esc(record.payload)}","denseB64":"${toBase64String(VectorCodecLike.encode(record.dense))}",'
            + '"saveTime":${record.saveTime}${title}${content}}'
        let body = call('hydra.upsert', '{"param":${param}}')
        let response = parse<BoolEnvelope>(body)
        if(!response.result){
            throw IllegalStateException('hydra.upsert failed for ${record.id}')
        }
        ()
    }

    public func get(collection: String, id: String): ?VectorRecord {
        let body = call('hydra.get',
                        '{"param":{"collection":"${esc(collection)}","id":"${esc(id)}"}}')
        let response = parse<RecordEnvelope>(body)
        if(!response.result.found){
            return None
        }
        let vectors = HashMap<String, Array<Float64>>()
        if(!response.result.titleDense.isEmpty()){
            vectors['title'] = response.result.titleDense.toArray()
        }
        if(!response.result.contentDense.isEmpty()){
            vectors['content'] = response.result.contentDense.toArray()
        }
        let sparse = HashMap<Int64, Float64>()
        for(index in 0..response.result.tokenIds.size){
            if(index < response.result.weights.size){
                sparse[response.result.tokenIds[index]] = response.result.weights[index]
            }
        }
        Some(VectorRecord(response.result.id, response.result.payload,
                          response.result.dense.toArray(),
                          sparse: sparse, colbert: response.result.colbert,
                          vectors: vectors, saveTime: response.result.saveTime))
    }

    public func remove(collection: String, id: String): Bool {
        let body = call('hydra.remove',
                        '{"param":{"collection":"${esc(collection)}","id":"${esc(id)}"}}')
        parse<BoolEnvelope>(body).result
    }

    public func searchDenseField(collection: String, field: String,
                                 dense: Array<Float64>, limit: Int64): ArrayList<VectorHit> {
        let param = '{"collection":"${esc(collection)}","field":"${esc(field)}",'
            + '"denseB64":"${toBase64String(VectorCodecLike.encode(dense))}","limit":${limit}}'
        hits(call('hydra.searchDense', '{"param":${param}}'))
    }

    public func searchSparse(collection: String, tokens: HashMap<Int64, Float64>,
                             limit: Int64): ArrayList<VectorHit> {
        var ids = ''
        var weights = ''
        for((token, weight) in tokens){
            if(!ids.isEmpty()){
                ids += ','
                weights += ','
            }
            ids += token.toString()
            weights += weight.toString()
        }
        let param = '{"collection":"${esc(collection)}","tokenIds":[${ids}],'
            + '"weights":[${weights}],"limit":${limit}}'
        hits(call('hydra.searchSparse', '{"param":${param}}'))
    }

    public func ids(collection: String, offset: Int64, limit: Int64): ArrayList<String> {
        let param = '{"collection":"${esc(collection)}","offset":${offset},"limit":${limit}}'
        let response = parse<IdsEnvelope>(call('hydra.ids', '{"param":${param}}'))
        let result = ArrayList<String>()
        for(id in response.result.ids){
            result.add(id)
        }
        result
    }

    // ---- internal ----

    private func hits(body: String): ArrayList<VectorHit> {
        let response = parse<HitsEnvelope>(body)
        let result = ArrayList<VectorHit>()
        for(hit in response.result.hits){
            result.add(VectorHit(hit.id, hit.payload, hit.score))
        }
        result
    }

    private func call(method: String, params: String): String {
        if(secret.isEmpty()){
            throw IllegalStateException('llm_hydraSecret is not configured')
        }
        let body = '{"jsonrpc":"2.0","id":1,"method":"${method}","params":${params}}'
        let client = HttpClient(url)
        client.header('Content-Type', 'application/json')
        client.header('Accept', 'application/json')
        client.header(KEY_HEADER, secret)
        var tls = TlsClientConfig()
        tls.verifyMode = CertificateVerifyMode.TrustAll
        client.tlsConfig(tls)
        resource(client){http =>
            let response = http.post(body)
            if(Int64(response.status) >= 400){
                throw IllegalStateException('hydra rpc failed, status ${response.status}')
            }
            let text = response.readEntire()
            let envelope = parse<ErrorEnvelope>(text)
            if(envelope.error.code != 0){
                throw IllegalStateException('hydra rpc error ${envelope.error.code}: ${envelope.error.message}')
            }
            text
        }
    }

    private static func parse<T>(text: String): T where T <: ObjectData<T> & DataFields<T> {
        let data = JsonValue.fromStr(text).toData()
        match(DataObject<T>.populate(data)){
            case Some(value) => value
            case None => throw IllegalStateException('hydra rpc response is not a valid ${text}')
        }
    }

    private static func numbers(values: Array<Float64>): String {
        var text = '['
        for(index in 0..values.size){
            if(index > 0){
                text += ','
            }
            text += values[index].toString()
        }
        text + ']'
    }

    private static func esc(text: String): String {
        var result = ''
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
            }else{
                result += String.fromUtf8([ch])
            }
        }
        result
    }
}

/** 只用于 dense → f32 字节（与 f_hydra 的 VectorCodec 布局一致：无 count 头） */
class VectorCodecLike {
    static func encode(values: Array<Float64>): Array<Byte> {
        let bytes = Array<Byte>(values.size * 4, repeat: 0)
        var offset = 0
        for(value in values){
            let bits = Float32(value).toBits()
            bytes[offset] = UInt8(bits & 0xFF)
            bytes[offset + 1] = UInt8((bits >> 8) & 0xFF)
            bytes[offset + 2] = UInt8((bits >> 16) & 0xFF)
            bytes[offset + 3] = UInt8((bits >> 24) & 0xFF)
            offset += 4
        }
        bytes
    }
}

// ---- JSON-RPC 响应 DTO ----

@DataAssist[fields props]
class ErrorDto {
    public var code: Int64 = 0
    public var message: String = ''

    public init() {
    }
}

@DataAssist[fields props]
class ErrorEnvelope {
    public var error: ErrorDto = ErrorDto()

    public init() {
    }
}

@DataAssist[fields props]
class BoolEnvelope {
    public var result: Bool = false

    public init() {
    }
}

@DataAssist[fields props]
class HitDto2 {
    public var id: String = ''
    public var payload: String = ''
    public var score: Float64 = 0.0

    public init() {
    }
}

@DataAssist[fields props]
class HitsDto2 {
    public var hits: ArrayList<HitDto2> = ArrayList<HitDto2>()

    public init() {
    }
}

@DataAssist[fields props]
class HitsEnvelope {
    public var result: HitsDto2 = HitsDto2()

    public init() {
    }
}

@DataAssist[fields props]
class RecordDto2 {
    public var found: Bool = false
    public var id: String = ''
    public var payload: String = ''
    public var dense: ArrayList<Float64> = ArrayList<Float64>()
    public var titleDense: ArrayList<Float64> = ArrayList<Float64>()
    public var contentDense: ArrayList<Float64> = ArrayList<Float64>()
    public var tokenIds: ArrayList<Int64> = ArrayList<Int64>()
    public var weights: ArrayList<Float64> = ArrayList<Float64>()
    public var colbert: Array<Array<Float64>> = Array<Array<Float64>>()
    public var saveTime: Int64 = 0

    public init() {
    }
}

@DataAssist[fields props]
class RecordEnvelope {
    public var result: RecordDto2 = RecordDto2()

    public init() {
    }
}

@DataAssist[fields props]
class IdsDto2 {
    public var ids: ArrayList<String> = ArrayList<String>()

    public init() {
    }
}

@DataAssist[fields props]
class IdsEnvelope {
    public var result: IdsDto2 = IdsDto2()

    public init() {
    }
}

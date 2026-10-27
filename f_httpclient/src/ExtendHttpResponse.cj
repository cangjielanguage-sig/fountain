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
package fountain::f_httpclient

import std.collection.ArrayList
import std.io.{InputStream, StringReader}

public import cangjie_tpc::charset4cj.charset.encoding.Charset
public import cangjie_tpc::charset4cj.charset.{Charsets, TextReader}

public import fountain::f_data.*
import fountain::f_base.*
import fountain::f_data.macros.*
import fountain::f_http.*
import fountain::f_http.exception.MediaTypeException

import fountain::f_httpclient.sse.*
public import fountain::f_httpclient.sse.*

public interface ExtendHttpResponse {
    func readToEnd(): Array<Byte>
    func reader(): StringReader<InputStream>
    func reader(charset: Charset): TextReader
    func readEntire(): String
    func readEntire(charset: Charset): String
    func tryParse<T>(): ?T where T <: DataFields<T>
    func convert<T>(): ?T where T <: DataFields<T>{
        tryParse<T>()
    }
    func readJson(): JsonValue
    func readJson(charset: Charset): JsonValue
    /** 把响应体当作 SSE（text/event-stream）读取；抽象函数不支持默认值，参数必须显式传 */
    func sseReader(maxLineBytes!: Int64, idleTimeout!: Duration): SseReader
}

extend HttpResponse <: ExtendHttpResponse {
    public func readToEnd(): Array<Byte> {
        let input = this.body
        if(let Some(size) <- this.bodySize){
            // 一次 read 不保证读满：已知长度也要循环，否则尾部是 0 字节（JSON 解析会报
            // “Unescaped control character"，看起来像上游发了非法 JSON）
            let buf = Array<Byte>(size, repeat: 0)
            var offset = 0
            while(offset < size){
                let read = input.read(buf[offset ..])
                if(read <= 0){
                    break
                }
                offset += read
            }
            if(offset == size){
                buf
            }else{
                buf[0 .. offset]
            }
        }else{
            let bytes = ArrayList<Byte>()
            let buf = Array<Byte>(1024, repeat: 0)
            while(let s <- input.read(buf) && s > 0){
                bytes.add(all: buf[0 .. s])
            }
            bytes.unsafeData()
        }
    }
    public func reader(): StringReader<InputStream> {
        StringReader<InputStream>(this.body)
    }

    /**
     * 把响应体当作 SSE（text/event-stream）读取。
     *
     * 只做语法解析：不解释 `[DONE]`、不解析 JSON、不自动重连；业务语义交给调用方。
     */
    public func sseReader(maxLineBytes!: Int64, idleTimeout!: Duration): SseReader {
        SseReader(this.body, maxLineBytes: maxLineBytes, idleTimeout: idleTimeout)
    }
    public func reader(charset: Charset): TextReader {
        TextReader(this.body, charset: charset)
    }
    public func readEntire(): String {
        readToEnd() |> String.unsafeUtf8
    }
    public func readEntire(charset: Charset): String {
        let bytes = readToEnd()
        charset.newDecoder().decode(bytes)
    }
    private func tryParse<T>(contentType: String): ?T where T <: DataFields<T> {
        if(let Some(s) <- this.bodySize){
            MediaTypes.tryParse(contentType).getOrThrow{
                MediaTypeException('${contentType} is not a valid media type')
            }.toDataFields<T>(this.body)
        }else{
            None<T>
        }
    }
    public func tryParse<T>(): ?T where T <: DataFields<T> {
        let contentType = this.headers.getFirst('Content-Type') ?? 'application/json'
        tryParse<T>(contentType)
    }
    public func readJson(): JsonValue {
        let json = readEntire()
        JsonValue.fromStr(json)
    }
    public func readJson(charset: Charset): JsonValue {
        let json = readEntire(charset)
        JsonValue.fromStr(json)
    }
}
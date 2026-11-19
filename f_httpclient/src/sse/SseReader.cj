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
package fountain::f_httpclient.sse

import std.collection.ArrayList
import std.convert.*
import std.io.InputStream
import std.time.MonoTime

/**
 * 阻塞式 SSE 读取器：一个实例对应一个响应体，非线程安全。
 *
 * 只做语法解析——`:` 注释丢弃、空行分隔事件、`data` 多行以 `\n` 拼接、
 * 字段值去掉一个前导空格；不解释 `[DONE]`、不解析 JSON、不自动重连。
 */
public class SseReader <: Resource {
    private static let BUFFER_SIZE: Int64 = 8192

    private let buffer = Array<Byte>(BUFFER_SIZE, repeat: 0)
    private var pos: Int64 = 0
    private var len: Int64 = 0
    private var eof = false
    private var closed = false
    private var lastActivityAt: ?MonoTime = None<MonoTime>
    private let body: InputStream
    private let maxLineBytes: Int64
    private let idleTimeout: Duration

    public init(
        body: InputStream,
        maxLineBytes!: Int64 = 1024 * 1024,
        idleTimeout!: Duration = Duration.second * 120
    ){
        this.body = body
        this.maxLineBytes = maxLineBytes
        this.idleTimeout = idleTimeout
    }

    public func isClosed(): Bool {
        closed
    }

    public func close(): Unit {
        if(!closed){
            closed = true
            // InputStream 本身不保证可关闭；能关的（如响应体）才关，避免误关调用方的流
            if(let resource: Resource <- body){
                try{
                    resource.close()
                }catch(_: Exception){}
            }
        }
    }

    /** 取下一条事件；流正常结束返回 None */
    public func next(): ?SseEvent {
        if(closed){
            return None<SseEvent>
        }
        var eventName = ''
        let data = ArrayList<String>()
        var id = ''
        var retry: Int64 = -1
        var hasField = false
        while(true){
            let line = readLine()
            if(let None <- line){
                if(!hasField){
                    return None<SseEvent>
                }
                return Some(SseEvent(eventName, joinData(data), id, retry))
            }
            let text = line.getOrThrow()
            if(text.isEmpty()){
                if(!hasField){
                    continue
                }
                return Some(SseEvent(eventName, joinData(data), id, retry))
            }
            if(text.startsWith(':')){
                continue
            }
            let colon = text.indexOf(':')
            if(let None <- colon){
                continue
            }
            let at = colon.getOrThrow()
            let field = text[0 .. at]
            var value = text[at + 1 ..]
            if(value.startsWith(' ')){
                value = value[1 ..]
            }
            match(field){
                case 'event' =>
                    eventName = value
                    hasField = true
                case 'data' =>
                    data.add(value)
                    hasField = true
                case 'id' =>
                    id = value
                    hasField = true
                case 'retry' =>
                    retry = Int64.tryParse(value) ?? -1
                    hasField = true
                case _ => ()
            }
        }
        None<SseEvent>
    }

    private func joinData(data: ArrayList<String>): String {
        if(data.isEmpty()){
            return ''
        }
        let builder = StringBuilder()
        var first = true
        for(item in data){
            if(!first){
                builder.append('\n')
            }
            builder.append(item)
            first = false
        }
        builder.toString()
    }

    /**
     * 读一行（不含行尾 \n，去掉行尾 \r）。
     * 返回 None 表示流已结束且没有残留数据；半行结束返回残留内容。
     */
    private func readLine(): ?String {
        let bytes = ArrayList<Byte>()
        var sawAny = false
        while(true){
            if(pos >= len){
                if(eof){
                    if(!sawAny){
                        return None<String>
                    }
                    return String.fromUtf8(bytes.toArray())
                }
                fill()
                continue
            }
            let b = buffer[pos]
            pos++
            sawAny = true
            if(b == 0x0A){
                var end = bytes.size
                if(end > 0 && bytes[end - 1] == 0x0D){
                    end--
                }
                return String.fromUtf8(bytes[0 .. end].toArray())
            }
            bytes.add(b)
            if(bytes.size > maxLineBytes){
                throw SseLineTooLongException(maxLineBytes)
            }
        }
        None<String>
    }

    /** 从底层流补一块数据；空闲超时在阻塞读之前判定 */
    private func fill(): Unit {
        if(closed){
            eof = true
            return
        }
        if(let Some(last) <- lastActivityAt){
            if(idleTimeout > Duration.Zero && MonoTime.now() - last > idleTimeout){
                throw SseTimeoutException(idleTimeout)
            }
        }
        lastActivityAt = Some(MonoTime.now())
        let n = body.read(buffer)
        if(n <= 0){
            eof = true
            pos = 0
            len = 0
            return
        }
        pos = 0
        len = n
    }
}

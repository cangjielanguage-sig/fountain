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
    private static let INITIAL_LINE_BYTES: Int64 = 256

    private let buffer = Array<Byte>(BUFFER_SIZE, repeat: 0)
    /** 可复用的行字节缓冲；只有 [0, lineLen) 是有效前缀。 */
    private var lineBuf: Array<Byte>
    private var lineLen: Int64 = 0
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
        var initial = INITIAL_LINE_BYTES
        if(initial > maxLineBytes){
            initial = maxLineBytes
        }
        if(initial < 0){
            initial = 0
        }
        this.lineBuf = Array<Byte>(initial, repeat: 0)
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
        lineLen = 0
        var sawAny = false
        while(true){
            if(pos >= len){
                if(eof){
                    if(!sawAny){
                        return None<String>
                    }
                    return takeLine(stripCr: false)
                }
                fill()
                continue
            }
            let b = buffer[pos]
            pos++
            sawAny = true
            if(b == 0x0A){
                return takeLine(stripCr: true)
            }
            if(lineLen >= maxLineBytes){
                lineLen = 0
                throw SseLineTooLongException(maxLineBytes)
            }
            ensureLineCapacity(lineLen + 1)
            lineBuf[lineLen] = b
            lineLen += 1
        }
        None<String>
    }

    /** 把 [0, lineLen) 拷贝到更大的数组；容量上限 maxLineBytes。 */
    private func ensureLineCapacity(need: Int64): Unit {
        if(need <= lineBuf.size){
            return
        }
        var want = lineBuf.size
        while(want < need){
            if(want >= maxLineBytes / 2){
                want = maxLineBytes
                break
            }
            want = want * 2
        }
        let grown = Array<Byte>(want, repeat: 0)
        for(i in 0 .. lineLen){
            grown[i] = lineBuf[i]
        }
        lineBuf = grown
    }

    /**
     * 用已写前缀构造一行并复位。
     * stripCr 只在以 \n 结束的行上为 true：EOF 半行保留末尾 \r（现状行为）。
     */
    private func takeLine(stripCr!: Bool): String {
        var end = lineLen
        if(stripCr && end > 0 && lineBuf[end - 1] == 0x0D){
            end -= 1
        }
        lineLen = 0
        String.fromUtf8(lineBuf[0 .. end])
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

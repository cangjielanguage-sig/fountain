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
package fountain::f_jsonrpc.client

import std.collection.*
import std.convert.*

/** 一帧 SSE：`id` 用于断线补发，`event` 目前恒为 `message`，`data` 是 JSON-RPC 通知 */
public class SseFrame {
    public let id: Int64
    public let event: String
    public let data: String

    init(id: Int64, event: String, data: String) {
        this.id = id
        this.event = event
        this.data = data
    }
}

/**
 * SSE 帧解析：按字节喂入，吐出完整帧。
 *
 * 分块边界任意（一块可能半个帧、也可能几帧），所以未消费的部分留在内部缓冲里。
 * 注释行（`: ping`）与未知字段直接忽略。
 */
public class SseFrameParser {
    private var buffer: String = ''

    public init() {
    }

    /** 重连时清掉半帧，避免新旧连接的数据拼在一起 */
    public func reset(): Unit {
        buffer = String()
    }

    public func feed(chunk: String): ArrayList<SseFrame> {
        buffer += chunk
        let frames = ArrayList<SseFrame>()
        while (true) {
            let end = match (findSeparator()) {
                case Some(value) => value
                case None => break
            }
            let block = buffer[..end]
            buffer = buffer[end + 2..]
            match (parse(block)) {
                case Some(frame) => frames.add(frame)
                case None => ()
            }
        }
        frames
    }

    /** 找帧分隔空行（`\n\n`）；顺带兼容 CRLF */
    private func findSeparator(): ?Int64 {
        let lf = buffer.indexOf('\n\n')
        let crlf = buffer.indexOf('\r\n\r\n')
        return match (lf) {
            case Some(a) => match (crlf) {
                case Some(b) => if (b < a) {
                    Some(b)
                } else {
                    Some(a)
                }
                case None => Some(a)
            }
            case None => crlf
        }
    }

    private func parse(block: String): ?SseFrame {
        var id: Int64 = 0
        var event = 'message'
        let data = StringBuilder()
        var hasData = false
        for (rawLine in block.split('\n')) {
            let line = rawLine.trimAscii()
            if (line.isEmpty() || line.startsWith(':')) {
                continue
            }
            match (line.indexOf(':')) {
                case Some(at) =>
                    let field = line[..at]
                    let value = if (at + 1 < Int64(line.size)) {
                        line[at + 1..].trimAscii()
                    } else {
                        ''
                    }
                    if (field == 'id') {
                        match (Int64.tryParse(value)) {
                            case Some(number) => id = number
                            case None => ()
                        }
                    } else if (field == 'event') {
                        event = value
                    } else if (field == 'data') {
                        if (hasData) {
                            data.append('\n')
                        }
                        data.append(value)
                        hasData = true
                    }
                case None => ()
            }
        }
        if (!hasData) {
            return None
        }
        SseFrame(id, event, data.toString())
    }
}

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
package fountain::f_email.transport

import std.collection.ArrayList
import std.io.{InputStream, OutputStream}

/**
 * 测试替身：按固定块大小返回预置字节，用来模拟"每次 read 只给 1 字节"的慢速流。
 */
class FixedInput <: InputStream {
    private let bytes: Array<Byte>
    private let chunk: Int64
    private var pos = 0

    init(bytes: Array<Byte>, chunk!: Int64 = 0) {
        this.bytes = bytes
        this.chunk = chunk
    }

    init(text: String, chunk!: Int64 = 0) {
        this.bytes = text.toArray()
        this.chunk = chunk
    }

    public func read(buffer: Array<Byte>): Int64 {
        if (pos >= bytes.size) {
            return 0
        }
        let available = bytes.size - pos
        var take = if (chunk > 0 && chunk < available) {
            chunk
        } else {
            available
        }
        if (take > buffer.size) {
            take = buffer.size
        }
        for (i in 0..take) {
            buffer[i] = bytes[pos + i]
        }
        pos += take
        take
    }
}

/** 测试替身：收集所有写出的字节。 */
class CollectOutput <: OutputStream {
    private let buffer = ArrayList<Byte>()

    public func write(bytes: Array<Byte>): Unit {
        for (b in bytes) {
            buffer.add(b)
        }
    }

    func bytes(): Array<Byte> {
        buffer.toArray()
    }

    func text(): String {
        String.fromUtf8(buffer.toArray())
    }

    func clear(): Unit {
        buffer.clear()
    }
}

/** 记录跟踪事件，用于断言脱敏与 IDLE 行是否走到 onLine。 */
class RecordingTrace <: MailTrace {
    let lines = ArrayList<(Rune, String)>()
    var bytes: Int64 = 0

    public func onLine(direction: Rune, line: String): Unit {
        lines.add((direction, line))
    }

    public func onBytes(direction: Rune, count: Int64): Unit {
        bytes += count
    }

    func textLines(): Array<String> {
        let out = ArrayList<String>()
        for ((_, line) in lines) {
            out.add(line)
        }
        out.toArray()
    }
}

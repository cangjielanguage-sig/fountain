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
package fountain::f_xml

import std.io.InputStream

/** 已经解码好的文本（`parse(text)` 入口）当作字节流用。 */
internal class TextInputStream <: InputStream {
    private let data: Array<Byte>
    private var pos: Int64 = 0

    init(text: String) {
        this.data = text.toArray()
    }

    init(data: Array<Byte>) {
        this.data = data
    }

    public func read(buffer: Array<Byte>): Int64 {
        if (this.pos >= this.data.size) {
            return 0
        }
        var n = this.data.size - this.pos
        if (n > buffer.size) {
            n = buffer.size
        }
        for (i in 0..n) {
            buffer[i] = this.data[this.pos + i]
        }
        this.pos += n
        n
    }
}

/**
 * 前缀回放流：先把 `prefix` 原样吐出，再接上 `rest`。
 *
 * 字节嗅探为了判 BOM / 魔数 / 声明必须提前读掉若干字节，这些字节不能丢——
 * 它们属于文档内容，回放给解码器即可。本类**不做任何编码判断**，纯字节搬运。
 *
 * EOF 返回 `0`（`InputStream` 的约定，也是 `charset4cj.TextReader` 的判定依据）。
 */
public class PrefixStream <: InputStream {
    private let prefix: Array<Byte>
    private let rest: InputStream
    private var offset: Int64 = 0

    public init(prefix: Array<Byte>, rest: InputStream) {
        this.prefix = prefix
        this.rest = rest
    }

    public func read(buffer: Array<Byte>): Int64 {
        if (this.offset < this.prefix.size) {
            let count = min(buffer.size, this.prefix.size - this.offset)
            for (i in 0..count) {
                buffer[i] = this.prefix[this.offset + i]
            }
            this.offset += count
            return count
        }
        return this.rest.read(buffer)
    }

    /** 关闭底层流（若它实现了 `Resource`）。 */
    public func close(): Unit {
        if (let resource: Resource <- this.rest) {
            resource.close()
        }
    }
}

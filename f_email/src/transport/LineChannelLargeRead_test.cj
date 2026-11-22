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

import std.io.OutputStream
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_email.model.MailIoException

/**
 * `readExact` 跨 64 KB 缓冲边界：按不同分块大小供给，结果必须逐字节一致。
 */
@Test
public class LineChannelLargeRead_test {

    @TestCase
    public func largeLiteralAcrossChunkSizes(): Unit {
        let total: Int64 = 128 * 1024
        let payload = patterned(total)
        for (chunk in [1, 7, 4096, 65536]) {
            let header = "A1 OK {131072}\r\n".toArray()
            let all = Array<Byte>(header.size + payload.size, repeat: 0)
            header.copyTo(all, 0, 0, header.size)
            payload.copyTo(all, 0, header.size, payload.size)
            let channel = LineChannel(FixedInput(all, chunk: chunk), BufferSink())
            @Expect(String.fromUtf8(channel.readLine() ?? Array<Byte>()), "A1 OK {131072}")
            let got = channel.readExact(total)
            @Expect(got.size, total)
            var mismatch: Int64 = 0
            for (i in 0..total) {
                if (got[i] != payload[i]) {
                    mismatch += 1
                }
            }
            @Expect(mismatch, 0)
        }
    }

    @TestCase
    public func eofBeforeCountStillThrows(): Unit {
        let channel = LineChannel(FixedInput("A1 OK {16}\r\nshort"), BufferSink())
        @Expect(String.fromUtf8(channel.readLine() ?? Array<Byte>()), "A1 OK {16}")
        var thrown = false
        try {
            channel.readExact(16)
        } catch (e: MailIoException) {
            thrown = true
        }
        @Expect(thrown, true)
    }

    private func patterned(size: Int64): Array<Byte> {
        let bytes = Array<Byte>(size, repeat: 0)
        for (i in 0..size) {
            bytes[i] = UInt8(i % 251)
        }
        bytes
    }
}

/** 只接收、不检查的 sink。 */
class BufferSink <: OutputStream {
    private var count: Int64 = 0

    public func write(buffer: Array<Byte>): Unit {
        count += buffer.size
    }

    public func flush(): Unit {}
}

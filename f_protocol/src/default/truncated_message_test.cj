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
package fountain::f_protocol.default

import std.io.{BufferedInputStream, ByteBuffer, SeekPosition}
import std.unittest.*
import std.unittest.testmacro.*

/**
 * “半条消息”在**协议层**的语义：写端写一半就断链，对端读到 0 字节 = 写端已关闭 = 数据不完整，
 * 因此 `Message.decode` 必须**抛**，而不是：
 *   - 把 INPUTSTREAM 载荷零填充后当成完整消息返回（f_codec 的 inline 分支）；
 *   - 在 data 字段起始处遇到 EOF 时静默返回“没有 data”的消息（f_codec 的 decodeData）。
 */
@Test
public class Truncated_message_test {
    /** 把一条消息编码成线上字节。 */
    private func wireOf(message: Message): Array<Byte> {
        let buf = ByteBuffer()
        message.encode().copy(to: buf, closeToOnEnd: false)
        buf.seek(SeekPosition.Begin(0))
        let all = Array<Byte>(1 << 20, repeat: 0)
        let n = buf.read(all)
        all[0..n]
    }
    /** 只喂前 keep 个字节，解码是否“抛”。 */
    private func decodeThrows(all: Array<Byte>, keep: Int64): Bool {
        let buf = ByteBuffer()
        buf.write(all[0..keep])
        buf.seek(SeekPosition.Begin(0))
        try {
            Message.decode<DataAny>(BufferedInputStream(buf))
            false
        } catch (_: Exception) {
            true
        }
    }
    /** n 字节的 INPUTSTREAM 载荷。 */
    private func payload(n: Int64): Data {
        DataCollection<Array<Byte>, Byte>(Array<Byte>(n, repeat: 0x41))
    }
    /** data 字段单独编码后的长度（用于把切点放在字段边界上）。 */
    private func dataFieldSize(data: Data): Int64 {
        DefaultCodec().encode(data).finish().byteSize() ?? -1
    }

    /** 完整消息必须能正常解出来（防止把修复做成“一律抛”）。 */
    @TestCase
    public func completeMessageStillDecodes(): Unit {
        let all = wireOf(Message(Command.REGISTER, payload(1000)))
        @Assert(decodeThrows(all, all.size) == false)
    }

    /** 载荷 1000B（<= fileThreshold）：砍掉尾部 300B 必须抛，而不是零填充出 1000B。 */
    @TestCase
    public func truncatedInlinePayloadMustThrow(): Unit {
        let all = wireOf(Message(Command.REGISTER, payload(1000)))
        @Assert(decodeThrows(all, all.size - 300))
    }

    /** 载荷 9000B（> fileThreshold，走流式分支）：截断后必须抛。 */
    @TestCase
    public func truncatedStreamedPayloadMustThrow(): Unit {
        let all = wireOf(Message(Command.REGISTER, payload(9000)))
        @Assert(decodeThrows(all, all.size - 5000))
    }

    /** EOF 恰好落在 data 字段起始处：必须抛，不能静默变成“没有 data”的消息。 */
    @TestCase
    public func eofAtDataFieldMustThrow(): Unit {
        let all = wireOf(Message(Command.REGISTER, payload(16)))
        let dataSize = dataFieldSize(payload(16))
        @Assert(dataSize > 0)
        @Assert(decodeThrows(all, all.size - dataSize))
    }
}

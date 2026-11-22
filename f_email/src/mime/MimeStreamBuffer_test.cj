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
package fountain::f_email.mime

import std.env.getVariable
import std.runtime.{gc, getAllocatedHeapSize, getGCFreedSize}
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_email.model.*

/**
 * 流式写出的缓冲复用：正文跨 64 KB 边界时仍逐字节正确。
 *
 * `PartBody.Data` 走 `writeLeafStream`；同尺寸的 `PartBody.Text` 走内存路径，两条路径的
 * 编码结果不要求相同，这里只校验流式路径的载荷可完整往返。
 */
@Test
public class MimeStreamBuffer_test {

    @TestCase
    public func roundTripsAcrossBufferBoundary(): Unit {
        for (size in [32 * 1024, 64 * 1024, 192 * 1024]) {
            let payload = patterned(size)
            let message = MailMessage.builder()
                .from("a@x.com")
                .to("b@y.com")
                .subject("buffer reuse")
                .text("body")
                .attach("big.bin", MemoryBodySource(payload))
                .build()
            let out = BufferOutput()
            MimeWriter(out).write(message)
            let parsed = MimeParser.parse(BufferInput(out.bytes()))
            let attachments = parsed.attachments()
            @Expect(attachments.size, 1)
            let got = readAllBytes((attachments[0].source() ?? MemoryBodySource(Array<Byte>())).open())
            @Expect(got.size, payload.size)
            var mismatch: Int64 = 0
            for (i in 0..payload.size) {
                if (got[i] != payload[i]) {
                    mismatch += 1
                }
            }
            @Expect(mismatch, 0)
        }
    }

    /** 记录 192 KB 流式附件的写出分配；不作硬门禁（GC 时机不可控）。 */
    @TestCase
    public func benchStreamBuffer(): Unit {
        if (!benchEnabled()) {
            println("EMAIL_STREAM_BENCH skipped (F_EMAIL_BENCH != 1)")
            return
        }
        let payload = patterned(192 * 1024)
        let message = MailMessage.builder()
            .from("a@x.com")
            .to("b@y.com")
            .subject("bench")
            .text("body")
            .attach("big.bin", MemoryBodySource(payload))
            .build()
        settle()
        let h0 = getAllocatedHeapSize()
        let f0 = getGCFreedSize()
        for (_ in 0..100) {
            MimeWriter(BufferOutput()).write(message)
        }
        let alloc = (getAllocatedHeapSize() - h0) + (getGCFreedSize() - f0)
        println("EMAIL_STREAM_BENCH payload=${payload.size} allocPerWrite=${alloc / 100}")
    }

    private func patterned(size: Int64): Array<Byte> {
        let bytes = Array<Byte>(size, repeat: 0)
        for (i in 0..size) {
            bytes[i] = UInt8(i % 251)
        }
        bytes
    }

    private func benchEnabled(): Bool {
        match (getVariable("F_EMAIL_BENCH")) {
            case Some(v) => v == "1"
            case None => false
        }
    }

    private func settle(): Unit {
        for (_ in 0..3) {
            gc()
        }
    }
}

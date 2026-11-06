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
package fountain::f_util

import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*

private func codegenBytes(n: Int64): Array<Byte> {
    Array<Byte>(n) { i => UInt8((i * 31 + 7) & 0xFF) }
}

/**
 * 生成式硬件 CRC（x86_64：CRC32C 的 `crc32` + ISO-HDLC 的 PCLMULQDQ）。
 *
 * 没有对应 CPU 特性的机器上 `availableFor()` 为 false，相关用例打印 SKIP 并返回，不失败。
 */
@When[os == "Linux" && arch == "x86_64"]
@Test
public class Crc32CodegenTest {
    @TestCase
    public func codeBufferAllocSeal(): Unit {
        match (CodeBuffer.alloc(64)) {
            case Some(buf) =>
                @Assert(buf.write([0xC3u8], 0))
                @Assert(buf.seal())
                @Assert(!buf.write([0xC3u8], 0)) // sealed 后不可写
                @Assert(!buf.rawPointer().isNull())
            case None => @Fail("mmap 失败")
        }
    }

    @TestCase
    public func crc32cKnownVector(): Unit {
        if (!Crc32Hw.availableFor(CrcHwKind.Crc32c)) {
            println("SKIP: 无 SSE4.2/CRC32C 硬件路径")
            return
        }
        let data: Array<Byte> = [49u8, 50u8, 51u8, 52u8, 53u8, 54u8, 55u8, 56u8, 57u8]
        @Assert(Crc32.crc32c.compute(data) == 0xE3069283u32)
    }

    @TestCase
    public func crc32cMatchesSoftwareForRandomLengths(): Unit {
        if (!Crc32Hw.availableFor(CrcHwKind.Crc32c)) {
            println("SKIP: 无 SSE4.2/CRC32C 硬件路径")
            return
        }
        let lengths: Array<Int64> = [0, 1, 2, 3, 7, 8, 9, 15, 16, 17, 63, 64, 65, 4095, 4096, 4097, 65536]
        for (n in lengths) {
            let data = codegenBytes(n)
            let hardware = Crc32.crc32c.compute(data)
            Crc32Hw.setNativeEnabled(false)
            let software = Crc32.crc32c.compute(data)
            Crc32Hw.setNativeEnabled(true)
            @Assert(hardware == software)
        }
    }

    @TestCase
    public func crc32cIncrementalMatchesOneShot(): Unit {
        if (!Crc32Hw.availableFor(CrcHwKind.Crc32c)) {
            println("SKIP: 无 SSE4.2/CRC32C 硬件路径")
            return
        }
        let data = codegenBytes(4097)
        let expected = Crc32.crc32c.compute(data)
        var crc = Crc32.crc32c.initRegister()
        var off = 0i64
        for (chunk in [1i64, 7, 16, 4096, 4097]) {
            let end = if (off + chunk > data.size) { data.size } else { off + chunk }
            if (end > off) {
                crc = Crc32.crc32c.update(crc, data[off..end])
                off = end
            }
        }
        @Assert(Crc32.crc32c.finish(crc) == expected)
    }

    @TestCase
    public func crc32cFallsBackWhenDisabled(): Unit {
        if (!Crc32Hw.availableFor(CrcHwKind.Crc32c)) {
            println("SKIP: 无 SSE4.2/CRC32C 硬件路径")
            return
        }
        let data = codegenBytes(4096)
        Crc32Hw.setNativeEnabled(false)
        let software = Crc32.crc32c.compute(data)
        Crc32Hw.setNativeEnabled(true)
        Crc32Hw.resetForTest()
        if (Crc32Hw.availableFor(CrcHwKind.Crc32c)) {
            @Assert(Crc32.crc32c.compute(data) == software)
        }
    }

    @TestCase
    public func crc32cConcurrentMatches(): Unit {
        if (!Crc32Hw.availableFor(CrcHwKind.Crc32c)) {
            println("SKIP: 无 SSE4.2/CRC32C 硬件路径")
            return
        }
        let data = codegenBytes(4096)
        let expected = Crc32.crc32c.compute(data)
        let futures = ArrayList<Future<UInt32>>()
        for (_ in 0..4) {
            futures.add(spawn {
                var value = 0u32
                for (_ in 0..1000) {
                    value = Crc32.crc32c.compute(data)
                }
                value
            })
        }
        for (f in futures) {
            @Assert(f.get() == expected)
        }
    }

    @TestCase
    public func crc32IsoKnownVector(): Unit {
        if (!Crc32Hw.availableFor(CrcHwKind.Iso)) {
            println("SKIP: 无 PCLMULQDQ/ISO 硬件路径")
            return
        }
        let data: Array<Byte> = [49u8, 50u8, 51u8, 52u8, 53u8, 54u8, 55u8, 56u8, 57u8]
        @Assert(Crc32.isoHdlc.compute(data) == 0xCBF43926u32)
    }

    @TestCase
    public func crc32IsoMatchesSoftwareForRandomLengths(): Unit {
        if (!Crc32Hw.availableFor(CrcHwKind.Iso)) {
            println("SKIP: 无 PCLMULQDQ/ISO 硬件路径")
            return
        }
        let lengths: Array<Int64> = [0, 1, 3, 15, 16, 17, 31, 32, 33, 63, 64, 65, 4095, 4096, 4097, 65536]
        for (n in lengths) {
            let data = codegenBytes(n)
            let hardware = Crc32.isoHdlc.compute(data)
            Crc32Hw.setNativeEnabled(false)
            let software = Crc32.isoHdlc.compute(data)
            Crc32Hw.setNativeEnabled(true)
            @Assert(hardware == software)
        }
    }

    @TestCase
    public func crc32IsoIncrementalMatchesOneShot(): Unit {
        if (!Crc32Hw.availableFor(CrcHwKind.Iso)) {
            println("SKIP: 无 PCLMULQDQ/ISO 硬件路径")
            return
        }
        let data = codegenBytes(4097)
        let expected = Crc32.isoHdlc.compute(data)
        var crc = Crc32.isoHdlc.initRegister()
        var off = 0i64
        for (chunk in [1i64, 15, 16, 17, 4096, 4097]) {
            let end = if (off + chunk > data.size) { data.size } else { off + chunk }
            if (end > off) {
                crc = Crc32.isoHdlc.update(crc, data[off..end])
                off = end
            }
        }
        @Assert(Crc32.isoHdlc.finish(crc) == expected)
    }
}

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
 * 生成式硬件 CRC（x86_64：`crc32` + PCLMULQDQ；aarch64：ARMv8 `crc32*`）。
 *
 * 没有对应 CPU 特性的机器上 `availableFor()` 为 false，相关用例打印 SKIP 并返回，不失败。
 */
@When[os == "Linux"]
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

    /**
     * 直接调用机器码入口，覆盖非对齐长度（1..7 字节尾部、8 的倍数、非 16 倍数）。
     *
     * `Crc32.update` 对 ISO 只把 16 字节整数倍交给硬件，本用例绕开该分层，
     * 让 `crc32b` / `crc32cb` 尾字节分支真正执行；初始寄存器用非标准值验证 raw 语义可链式。
     *
     * x86_64 的 ISO 生成函数按契约只接受 16 字节整数倍，其余长度返回 `None`（尾部由软件补）；
     * aarch64 的 `crc32x` 循环自带尾字节处理，任意长度都应返回结果。
     */
    @TestCase
    public func crc32HardwareRawMatchesSoftwareForUnalignedLengths(): Unit {
        let kinds: Array<CrcHwKind> = [CrcHwKind.Iso, CrcHwKind.Crc32c]
        let labels: Array<String> = ["ISO-HDLC", "CRC32C"]
        let lengths: Array<Int64> = [1, 2, 3, 5, 7, 8, 9, 15, 16, 17, 23, 24, 31, 33, 255, 256, 257, 4095, 4097]
        let seed = 0xDEADBEEFu32
        for (i in 0..kinds.size) {
            let kind = kinds[i]
            if (!Crc32Hw.availableFor(kind)) {
                println("SKIP: 无 ${labels[i]} 硬件路径")
                continue
            }
            // 探测该平台 ISO 入口是否只接受 16 字节整数倍（x86_64 是，aarch64 否）
            let alignedOnly = kind == CrcHwKind.Iso &&
                Crc32Hw.update(kind, seed, codegenBytes(3)).isNone()
            let variant = if (kind == CrcHwKind.Iso) { Crc32.isoHdlc } else { Crc32.crc32c }
            for (n in lengths) {
                let data = codegenBytes(n)
                let hardware = Crc32Hw.update(kind, seed, data)
                let software = try {
                    Crc32Hw.setNativeEnabled(false)
                    variant.update(seed, data)
                } finally {
                    Crc32Hw.setNativeEnabled(true)
                }
                match (hardware) {
                    case Some(value) => @Assert(value, software)
                    case None =>
                        // x86_64 对非 16 倍长度返回 None 属于契约；其余一律视为失败
                        if (alignedOnly && n % 16 != 0) {
                            continue
                        }
                        @Fail("${labels[i]} len=${n}: 硬件路径未返回结果")
                }
            }
            // 空输入不进机器码，交回软件
            @Assert(Crc32Hw.update(kind, seed, Array<Byte>()).isNone())
        }
    }
}

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
package fountain::f_jit.base

import std.unittest.*
import std.unittest.testmacro.*

/**
 * S1.4 `Version` 的失败用例（先写红）。
 *
 * 数值权威 = `doc/jit-bytecode-m1.md` §11.6 容器头表：`magic "FBC1"`、`verMajor 1`、
 * `verMinor 14`（v0.18.25）、`hdrSize 36`（新布局；旧单元 32）。头内偏移：
 * `0 magic / 4 verMajor / 6 verMinor / 8 flags / 12 hdrSize / 16 codeLen / 20 constLen /
 * 24 siteLen / 28 entryFn / 32 nameLen / 36 crc32 / 40 … 四段`，即
 * 「`payload = 4 + hdrSize`」（§11.6 表头注）。
 *
 * 端序按 §11.2「显式 LE」：把 `MAGIC` 这个 u32 按 LE 写出，得到的必须正好是 ASCII `FBC1` 四字节。
 */
@Test
public class Version_test {
    /** 四个常量与 §11.6 逐项一致。 */
    @TestCase
    public func constantsMatchSpecTable(): Unit {
        @Assert(Version.MAJOR, 1u16)
        @Assert(Version.MINOR, 14u16)
        @Assert(Version.HDR_SIZE, 36u32)
        @Assert(Version.MAGIC_TEXT, 'FBC1')
    }

    /** `MAGIC`（u32）按显式 LE 解出的四字节 == "FBC1" 的四个 ASCII 字节。 */
    @TestCase
    public func magicU32IsFBC1InLittleEndian(): Unit {
        @Assert(Version.MAGIC, 0x31434246u32)
        @Assert(UInt8(Version.MAGIC & 0xFFu32), 0x46u8) // 'F'
        @Assert(UInt8((Version.MAGIC >> 8) & 0xFFu32), 0x42u8) // 'B'
        @Assert(UInt8((Version.MAGIC >> 16) & 0xFFu32), 0x43u8) // 'C'
        @Assert(UInt8((Version.MAGIC >> 24) & 0xFFu32), 0x31u8) // '1'
    }

    /** 用这四个常量构造的最小容器头，能被同一版本的读取侧识别（magic 与长度字段匹配）。 */
    @TestCase
    public func minimalHeaderRoundTripsWithSameVersion(): Unit {
        let hdr = buildMinimalHeader(0u32, 0u32, 0u32, 0u32, 0u32)
        // 头总长 = 4（magic）+ hdrSize；payload 起点 = 4 + hdrSize（§11.6）
        @Assert(hdr.size, 40)
        @Assert(UInt32(hdr.size), 4u32 + Version.HDR_SIZE)
        @Assert(readU32(hdr, 0), Version.MAGIC)
        @Assert(readU16(hdr, 4), Version.MAJOR)
        @Assert(readU16(hdr, 6), Version.MINOR)
        @Assert(readU32(hdr, 12), Version.HDR_SIZE)
        // 读取侧按 magic 认版本：写方与读方共用同一份定义 ⇒ 恒等
        @Assert(readU32(hdr, 0) == Version.MAGIC, true)
        @Assert(readU16(hdr, 4) == Version.MAJOR, true)
    }

    /** 四段长度按写入值原样读回（字段偏移与 §11.6 表一致：16/20/24/28/32）。 */
    @TestCase
    public func sectionLengthsRoundTripAtSpecOffsets(): Unit {
        let hdr = buildMinimalHeader(11u32, 22u32, 33u32, 7u32, 44u32)
        @Assert(readU32(hdr, 16), 11u32) // codeLen
        @Assert(readU32(hdr, 20), 22u32) // constLen
        @Assert(readU32(hdr, 24), 33u32) // siteLen
        @Assert(readU32(hdr, 28), 7u32) // entryFn
        @Assert(readU32(hdr, 32), 44u32) // nameLen
        // 四段紧接头之后依次存放 ⇒ 总长 = payload 起点 + 四段长度之和
        let payload = 4u32 + Version.HDR_SIZE
        @Assert(readU32(hdr, 16) + readU32(hdr, 20) + readU32(hdr, 24) + readU32(hdr, 32), 110u32)
        @Assert(payload, 40u32)
    }

    // ---------------- Q0.1 多版本常量（M2 兼容基建） ----------------

    /** Q0.1：M1/M2/M3 版本常量逐项与 spec「版本常量」一致。 */
    @TestCase
    public func multiVersionConstantsMatchSpec(): Unit {
        @Assert(Version.M1_MAJOR, 1u16)
        @Assert(Version.M2_MAJOR, 2u16)
        @Assert(Version.M2_MINOR, 0u16)
        @Assert(Version.M3_MAJOR, 3u16)
    }

    /** Q0.1：`supportedMajors()` 含 v1/v2/v3（三者规则集均已实现）。 */
    @TestCase
    public func supportedMajorsCoversImplementedMajors(): Unit {
        let majors = Version.supportedMajors()
        var has1 = false
        var has2 = false
        var has3 = false
        for (m in majors) {
            if (m == 1u16) {
                has1 = true
            }
            if (m == 2u16) {
                has2 = true
            }
            if (m == 3u16) {
                has3 = true
            }
        }
        @Assert(has1, true)
        @Assert(has2, true)
        @Assert(has3, true)
        @Assert(majors.size, 3)
    }

    /** Q0.1：legacy `MAJOR/MINOR/HDR_SIZE/MAGIC` 与 M1 读取路径逐项不变。 */
    @TestCase
    public func legacyM1ConstantsUnchanged(): Unit {
        @Assert(Version.MAJOR, 1u16)
        @Assert(Version.MINOR, 14u16)
        @Assert(Version.HDR_SIZE, 36u32)
        @Assert(Version.MAGIC, 0x31434246u32)
        @Assert(Version.MAGIC_TEXT, 'FBC1')
        // M2 通过显式版本选择表达，不改写 legacy 写入口径
        @Assert(Version.MAJOR, Version.M1_MAJOR)
        @Assert(Version.MAJOR != Version.M2_MAJOR, true)
    }

    /** Q0.1：用 M2 版本常量构造的最小容器头字段自洽（magic / 头长口径沿用 M1）。 */
    @TestCase
    public func m2HeaderBuildsWithM2Constants(): Unit {
        let hdr = Array<UInt8>(40, repeat: 0u8)
        putU32(hdr, 0, Version.MAGIC)
        putU16(hdr, 4, Version.M2_MAJOR)
        putU16(hdr, 6, Version.M2_MINOR)
        putU32(hdr, 8, 1u32) // flags.bit0 = UTF-8，恒 1
        putU32(hdr, 12, Version.HDR_SIZE)
        @Assert(readU32(hdr, 0), Version.MAGIC)
        @Assert(readU16(hdr, 4), 2u16)
        @Assert(readU16(hdr, 6), 0u16)
        @Assert(readU32(hdr, 12), 36u32)
        @Assert(UInt32(hdr.size), 4u32 + Version.HDR_SIZE)
    }

    /** 按 §11.6 字段表构造一个最小容器头（显式 LE，禁 memcpy）。 */
    private func buildMinimalHeader(
        codeLen: UInt32,
        constLen: UInt32,
        siteLen: UInt32,
        entryFn: UInt32,
        nameLen: UInt32
    ): Array<UInt8> {
        let buf = Array<UInt8>(40, repeat: 0u8)
        putU32(buf, 0, Version.MAGIC)
        putU16(buf, 4, Version.MAJOR)
        putU16(buf, 6, Version.MINOR)
        putU32(buf, 8, 1u32) // flags.bit0 = UTF-8 语义，恒 1
        putU32(buf, 12, Version.HDR_SIZE)
        putU32(buf, 16, codeLen)
        putU32(buf, 20, constLen)
        putU32(buf, 24, siteLen)
        putU32(buf, 28, entryFn)
        putU32(buf, 32, nameLen)
        putU32(buf, 36, 0u32) // crc32（占位）
        buf
    }

    private func putU32(buf: Array<UInt8>, off: Int64, value: UInt32): Unit {
        buf[off] = UInt8(value & 0xFFu32)
        buf[off + 1] = UInt8((value >> 8) & 0xFFu32)
        buf[off + 2] = UInt8((value >> 16) & 0xFFu32)
        buf[off + 3] = UInt8((value >> 24) & 0xFFu32)
    }

    private func putU16(buf: Array<UInt8>, off: Int64, value: UInt16): Unit {
        buf[off] = UInt8(UInt32(value) & 0xFFu32)
        buf[off + 1] = UInt8((UInt32(value) >> 8) & 0xFFu32)
    }

    private func readU32(buf: Array<UInt8>, off: Int64): UInt32 {
        UInt32(buf[off]) | (UInt32(buf[off + 1]) << 8) | (UInt32(buf[off + 2]) << 16) |
            (UInt32(buf[off + 3]) << 24)
    }

    private func readU16(buf: Array<UInt8>, off: Int64): UInt16 {
        UInt16(UInt32(buf[off]) | (UInt32(buf[off + 1]) << 8))
    }
}

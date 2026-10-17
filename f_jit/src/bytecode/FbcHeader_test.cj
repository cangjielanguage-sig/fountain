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
package fountain::f_jit.bytecode

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.ArrayList
import fountain::f_jit.base.*
import fountain::f_base.*
import fountain::f_util.Crc32

/**
 * S2.11 `FbcFlags` / `FbcHeader` 与 S2.12 `FbcWriter` 的失败用例（先写红）。
 *
 * 权威 = `doc/jit-bytecode-m1.md` §11.6 容器头 `.fbc`：
 *
 * ```
 * off  size 字段
 * 0    4    magic "FBC1"      20   4   constLen
 * 4    2    verMajor          24   4   siteLen
 * 6    2    verMinor          28   4   entryFn
 * 8    4    flags             32   4   nameLen（v0.18.25 新增；≥ 4）
 * 12   4    hdrSize 36        36   4   crc32（code+const+site+name）
 * 16   4    codeLen           40   ... code / const / site / name 四段
 * ```
 *
 * **头布局兼容（v0.18.25）**：`nameLen` 插入 `crc32` 前——crc32 偏移 32→36、payload 起始
 * 36→40；加载器按 `verMinor` 分支：≤ 13 = 旧布局（无 `nameLen`、payload 36、无 name 段）。
 */
@Test
public class FbcHeader_test {
    /** flags 位定义与已知位掩码（§11.6：bit0 UTF-8、bit1 需 JIT 恒 0、bit2 值运算类）。 */
    @TestCase
    public func flagsBitsAndKnownMask(): Unit {
        @Assert(FbcFlags.UTF8, 1u32)
        @Assert(FbcFlags.NEED_JIT, 2u32)
        @Assert(FbcFlags.VALUE_OPS, 4u32)
        @Assert(FbcFlags.KNOWN_MASK, 7u32)
    }

    /** 新布局字段偏移断言（0/4/6/8/12/16/20/24/28/32/36）。 */
    @TestCase
    public func newLayoutFieldOffsets(): Unit {
        let h = FbcHeader(
            Version.MAGIC,
            Version.MAJOR,
            Version.MINOR,
            FbcFlags.UTF8,
            Version.HDR_SIZE,
            11u32,
            22u32,
            33u32,
            44u32,
            55u32,
            66u32)
        let w = ByteWriter()
        h.write(w)
        let bs = w.take()
        let r = ByteReader(bs)
        @Assert(r.offset(), 0)
        @Assert(r.u32(), Version.MAGIC) // magic        @0
        @Assert(r.offset(), 4)
        @Assert(r.u16(), Version.MAJOR) // verMajor     @4
        @Assert(r.offset(), 6)
        @Assert(r.u16(), Version.MINOR) // verMinor     @6
        @Assert(r.offset(), 8)
        @Assert(r.u32(), FbcFlags.UTF8) // flags        @8
        @Assert(r.offset(), 12)
        @Assert(r.u32(), Version.HDR_SIZE) // hdrSize   @12
        @Assert(r.offset(), 16)
        @Assert(r.u32(), 11u32) // codeLen              @16
        @Assert(r.offset(), 20)
        @Assert(r.u32(), 22u32) // constLen             @20
        @Assert(r.offset(), 24)
        @Assert(r.u32(), 33u32) // siteLen              @24
        @Assert(r.offset(), 28)
        @Assert(r.u32(), 44u32) // entryFn              @28
        @Assert(r.offset(), 32)
        @Assert(r.u32(), 55u32) // nameLen              @32
        @Assert(r.offset(), 36)
        @Assert(r.u32(), 66u32) // crc32                @36
        @Assert(r.offset(), 40)
    }

    /** 新布局读回与写出互逆；payload 起点 = 4 + hdrSize = 40。 */
    @TestCase
    public func newLayoutRoundTrip(): Unit {
        let h = FbcHeader(
            Version.MAGIC,
            1u16,
            14u16,
            FbcFlags.UTF8 | FbcFlags.VALUE_OPS,
            36u32,
            100u32,
            200u32,
            300u32,
            7u32,
            400u32,
            0xCAFEBABEu32)
        let w = ByteWriter()
        h.write(w)
        let back = FbcHeader.read(ByteReader(w.take()))
        @Assert(back.magic, h.magic)
        @Assert(back.verMajor, h.verMajor)
        @Assert(back.verMinor, h.verMinor)
        @Assert(back.flags, h.flags)
        @Assert(back.hdrSize, h.hdrSize)
        @Assert(back.codeLen, h.codeLen)
        @Assert(back.constLen, h.constLen)
        @Assert(back.siteLen, h.siteLen)
        @Assert(back.entryFn, h.entryFn)
        @Assert(back.nameLen, h.nameLen)
        @Assert(back.crc32, h.crc32)
        @Assert(back.payloadOff(), 40)
    }

    /**
     * 旧布局兼容（`verMinor ≤ 13`）：**无 `nameLen`**、payload 起点 36、`hdrSize = 32`。
     *
     * 手工构造一份旧布局头（magic…entryFn 共 32 字节 + crc32 4 字节 = 36），验证读法分支。
     */
    @TestCase
    public func legacyLayoutIsReadByCompatBranch(): Unit {
        let w = ByteWriter()
        w.wU32(Version.MAGIC) // @0
        w.wU16(1u16) // verMajor        @4
        w.wU16(13u16) // verMinor = 13  @6（旧布局）
        w.wU32(FbcFlags.UTF8) //        @8
        w.wU32(32u32) // hdrSize = 32   @12
        w.wU32(8u32) // codeLen         @16
        w.wU32(4u32) // constLen        @20
        w.wU32(4u32) // siteLen         @24
        w.wU32(0u32) // entryFn         @28
        w.wU32(0x11223344u32) // crc32  @32（旧布局：nameLen 位不存在）
        let bs = w.take()
        @Assert(bs.size, 36)

        let h = FbcHeader.read(ByteReader(bs))
        @Assert(h.verMinor, 13u16)
        @Assert(h.hdrSize, 32u32)
        @Assert(h.nameLen, 0u32) // 旧布局无 name 段
        @Assert(h.crc32, 0x11223344u32)
        @Assert(h.payloadOff(), 36) // 4 + 32
    }

    /** CRC-32/ISO-HDLC 基准向量：`crc32(空) = 0`、`crc32("123456789") = 0xCBF43926`。 */
    @TestCase
    public func crc32GoldenVectors(): Unit {
        @Assert(Crc32.isoHdlc.compute(Array<UInt8>()), 0u32)
        @Assert(Crc32.isoHdlc.compute('123456789'.unsafeBytes()), 0xCBF43926u32)
    }
}

/**
 * S2.12 `FbcWriter` 的失败用例（先写红）。
 *
 * `crc32` 覆盖 **code + const + site + name** 四段（§11.6）；写方与读方**同一口径**
 * （`fountain::f_util.Crc32.isoHdlc`，design D8）。
 */
@Test
public class FbcWriter_test {
    private func sampleSegments(): (Array<UInt8>, Array<UInt8>, Array<UInt8>, Array<UInt8>) {
        let code = [0x7Cu8, 0x03u8, 0x01u8, 0x00u8, 0x00u8, 0x00u8]
        let consts = ConstRegistry()
        consts.addI64(1)
        consts.freeze()
        let site = SiteTable()
        site.add(0u32, SourcePos(1, 1))
        site.freeze()
        let name = NameTable()
        name.add(0u32, 0u32, 'x')
        name.freeze()
        (code, consts.encode(), site.encode(), name.encode())
    }

    /** `build` 产物的 magic / verMajor / verMinor / 四个段长 / entryFn / flags 正确。 */
    @TestCase
    public func buildWritesHeaderFields(): Unit {
        let (code, cb, sb, nb) = sampleSegments()
        let w = FbcWriter()
        w.setEntryFn(3u32)
        w.setFlags(FbcFlags.UTF8 | FbcFlags.VALUE_OPS)
        w.setCode(code)
        w.setConst(cb)
        w.setSite(sb)
        w.setName(nb)
        let raw = w.build()

        let h = FbcHeader.read(ByteReader(raw))
        @Assert(h.magic, Version.MAGIC)
        @Assert(h.verMajor, Version.MAJOR)
        @Assert(h.verMinor, Version.MINOR)
        @Assert(h.flags, FbcFlags.UTF8 | FbcFlags.VALUE_OPS)
        @Assert(h.hdrSize, Version.HDR_SIZE)
        @Assert(h.codeLen, UInt32(code.size))
        @Assert(h.constLen, UInt32(cb.size))
        @Assert(h.siteLen, UInt32(sb.size))
        @Assert(h.nameLen, UInt32(nb.size))
        @Assert(h.entryFn, 3u32)
        @Assert(h.payloadOff(), 40)
        @Assert(raw.size, 40 + code.size + cb.size + sb.size + nb.size)
    }

    /** crc32 覆盖四段：改动任一段的**一个字节** ⇒ 校验和不同。 */
    @TestCase
    public func crc32CoversAllFourSegments(): Unit {
        let (code, cb, sb, nb) = sampleSegments()
        let base = buildWith(code, cb, sb, nb)
        let baseCrc = FbcHeader.read(ByteReader(base)).crc32
        @Assert(baseCrc != 0u32, true)

        // code 段改 1 字节
        let code2 = code.clone()
        code2[0] = 0x7Du8
        @Assert(FbcHeader.read(ByteReader(buildWith(code2, cb, sb, nb))).crc32 != baseCrc, true)
        // const 段改 1 字节
        let cb2 = cb.clone()
        cb2[cb2.size - 1] = cb2[cb2.size - 1] ^ 0xFFu8
        @Assert(FbcHeader.read(ByteReader(buildWith(code, cb2, sb, nb))).crc32 != baseCrc, true)
        // site 段改 1 字节（line 字段）
        let sb2 = sb.clone()
        sb2[8] = sb2[8] ^ 0x01u8
        @Assert(FbcHeader.read(ByteReader(buildWith(code, cb, sb2, nb))).crc32 != baseCrc, true)
        // name 段改 1 字节（名字首字节）
        let nb2 = nb.clone()
        nb2[20] = 0x79u8
        @Assert(FbcHeader.read(ByteReader(buildWith(code, cb, sb, nb2))).crc32 != baseCrc, true)
    }

    /** crc32 字段等于「四段拼接」的 `Crc32.isoHdlc`（写方口径 = 读方口径）。 */
    @TestCase
    public func crc32EqualsConcatenatedSegments(): Unit {
        let (code, cb, sb, nb) = sampleSegments()
        let raw = buildWith(code, cb, sb, nb)
        let h = FbcHeader.read(ByteReader(raw))
        var all = ArrayList<UInt8>()
        for (b in code) {
            all.add(b)
        }
        for (b in cb) {
            all.add(b)
        }
        for (b in sb) {
            all.add(b)
        }
        for (b in nb) {
            all.add(b)
        }
        @Assert(h.crc32, Crc32.isoHdlc.compute(all.toArray()))
    }

    private func buildWith(
        code: Array<UInt8>,
        cb: Array<UInt8>,
        sb: Array<UInt8>,
        nb: Array<UInt8>
    ): Array<UInt8> {
        let w = FbcWriter()
        w.setEntryFn(0u32)
        w.setFlags(FbcFlags.UTF8)
        w.setCode(code)
        w.setConst(cb)
        w.setSite(sb)
        w.setName(nb)
        w.build()
    }
}

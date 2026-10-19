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

/**
 * `.fbc` 容器头与 flags 位域 —— design-m1 §3.3.8、plan-m1 S2.11。
 *
 * 权威 = `doc/jit-bytecode-m1.md` §11.6：
 *
 * ```
 * off  size 字段        说明
 * 0    4    magic       "FBC1"
 * 4    2    verMajor    1
 * 6    2    verMinor    14
 * 8    4    flags       bit0=UTF-8 语义(恒 1)  bit1=需要 JIT(必须为 0)  bit2=使用值运算/分配/变更类指令
 * 12   4    hdrSize     36（v0.18.25 起；旧单元 32）——payload = 4 + hdrSize
 * 16   4    codeLen     20   4   constLen
 * 24   4    siteLen     28   4   entryFn
 * 32   4    nameLen     变量名表长度（v0.18.25 新增；≥ 4）
 * 36   4    crc32       code + const + site + name（CRC-32/ISO-HDLC）
 * 40   ...  code / const / site / name 四段依次存放
 * ```
 *
 * **头布局兼容（v0.18.25）**：`nameLen` 插入 `crc32` 前——`crc32` 偏移 32→36、payload 起始
 * 36→40。加载器按 `verMinor` 分支：≤ 13 = 旧布局（无 `nameLen`、payload 36、无 name 段）；
 * ≥ 14 = 新布局（payload = 4 + `hdrSize` = 40）。
 */

/** 容器头 flags 位域（§11.6）。 */
public class FbcFlags {
    /** bit0：UTF-8 语义（§11.6 记为「恒 1」）。 */
    public static const UTF8: UInt32 = 1u32
    /** bit1：需要 JIT（**必须恒为 0**，§11.6 冻结决策：`flags.bit1` 必须为 0）。 */
    public static const NEED_JIT: UInt32 = 2u32
    /** bit2：使用值运算 / 分配 / 变更类指令（helper 路由），置 1 时加载器按需预扩句柄表。 */
    public static const VALUE_OPS: UInt32 = 4u32
    /** 已知位掩码：本版本认识的全部位；**其余位一律视为未知**并在加载期拒绝（§11.6）。 */
    public static const KNOWN_MASK: UInt32 = 7u32
}

/** 容器头（struct：纯值、无身份，与 `.fbc` 字节一一对应）。 */
public struct FbcHeader {
    /** `"FBC1"` 的 u32 形态（LE 写出即四字节 ASCII）。 */
    public let magic: UInt32
    public let verMajor: UInt16
    public let verMinor: UInt16
    public let flags: UInt32
    /** magic 之后的头长度；`payload = 4 + hdrSize`。 */
    public let hdrSize: UInt32
    public let codeLen: UInt32
    public let constLen: UInt32
    public let siteLen: UInt32
    public let entryFn: UInt32
    /** 旧布局（verMinor ≤ 13）单元为 0——该版本**没有 name 段**。 */
    public let nameLen: UInt32
    public let crc32: UInt32

    public init(
        magic: UInt32,
        verMajor: UInt16,
        verMinor: UInt16,
        flags: UInt32,
        hdrSize: UInt32,
        codeLen: UInt32,
        constLen: UInt32,
        siteLen: UInt32,
        entryFn: UInt32,
        nameLen: UInt32,
        crc32: UInt32
    ) {
        this.magic = magic
        this.verMajor = verMajor
        this.verMinor = verMinor
        this.flags = flags
        this.hdrSize = hdrSize
        this.codeLen = codeLen
        this.constLen = constLen
        this.siteLen = siteLen
        this.entryFn = entryFn
        this.nameLen = nameLen
        this.crc32 = crc32
    }

    /** 旧布局的**最后一个** `verMinor`：≤ 13 的单元无 `nameLen`（§11.6）。 */
    public static const LEGACY_MINOR: UInt16 = 13u16

    /** 旧布局头长度（无 nameLen）。 */
    public static const LEGACY_HDR_SIZE: UInt32 = 32u32

    /** 是否旧布局（无 name 段、payload = 36）。 */
    public func isLegacyLayout(): Bool {
        this.verMinor <= LEGACY_MINOR
    }

    /** 四段 payload 的起点（= 4 + `hdrSize`，§11.6）。 */
    public func payloadOff(): Int64 {
        4 + Int64(this.hdrSize)
    }

    /** 按 §11.6 顺序写出头（新布局，含 `nameLen`）。 */
    public func write(w: ByteWriter): Unit {
        w.wU32(this.magic)
        w.wU16(this.verMajor)
        w.wU16(this.verMinor)
        w.wU32(this.flags)
        w.wU32(this.hdrSize)
        w.wU32(this.codeLen)
        w.wU32(this.constLen)
        w.wU32(this.siteLen)
        w.wU32(this.entryFn)
        w.wU32(this.nameLen)
        w.wU32(this.crc32)
    }

    /**
     * 按 `verMinor` 分支读入（§11.6「头布局兼容」）。
     *
     * - `verMinor ≤ 13`：**无 `nameLen`**，紧接 `entryFn` 的就是 `crc32`（`nameLen` 记 0）；
     * - `verMinor ≥ 14`：先 `nameLen` 再 `crc32`。
     *
     * 版本 / flags / magic 的**语义校验**不在这里（见 `FbcReader.validate`，design D11「11 类
     * 非法情形集中在一个 `validate` 里」）——本方法只负责把字节解成字段。
     */
    public static func read(r: ByteReader): FbcHeader {
        let magic = r.u32()
        let verMajor = r.u16()
        let verMinor = r.u16()
        let flags = r.u32()
        let hdrSize = r.u32()
        let codeLen = r.u32()
        let constLen = r.u32()
        let siteLen = r.u32()
        let entryFn = r.u32()
        var nameLen: UInt32 = 0u32
        var crc32: UInt32 = 0u32
        if (verMinor <= LEGACY_MINOR) {
            crc32 = r.u32()
        } else {
            nameLen = r.u32()
            crc32 = r.u32()
        }
        FbcHeader(magic, verMajor, verMinor, flags, hdrSize, codeLen, constLen, siteLen, entryFn, nameLen, crc32)
    }
}

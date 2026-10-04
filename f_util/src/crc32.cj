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

import fountain::f_base.*

/**
 * CRC-32 各变体（参数口径见 `CrcEngine`，检查值是 `"123456789"` 的 CRC-32）。
 *
 * 用法：
 * ```
 * let c = Crc32.isoHdlc.compute(bytes)          // zlib/gzip/PNG 用的那个
 * let c2 = Crc32.crc32c.compute(bytes)          // iSCSI/SSE4.2 硬件指令支持的那个
 * let c3 = Crc32.crc32c.initRegister()          // 增量：init -> update -> finish
 * ```
 *
 * 注：旧的顶层函数 `crc32(...)` / `crc32Init()` / `crc32Update()` / `crc32Finish()` 等价于
 * `Crc32.isoHdlc`（CRC-32/ISO-HDLC，即 IEEE 802.3 / zlib），保留兼容；帧校验（f_protocol）与
 * WAL 校验（f_store）用的就是它。
 */
public class Crc32 {
    // ---- 反射（LSB-first）----
    /** CRC-32/ISO-HDLC（同 ADCCP/PKZIP/V-42/XZ 里非 64 位那个）：zlib/gzip/PNG/以太网。 */
    public static let isoHdlc = Crc32('CRC-32/ISO-HDLC', 0x04C11DB7, 0xFFFFFFFF, true, true, 0xFFFFFFFF, 0xCBF43926)
    /** CRC-32/JAMCRC：同 ISO-HDLC 但 **不做** 末尾异或（即 ISO-HDLC 的结果再取反）。 */
    public static let jamcrc = Crc32('CRC-32/JAMCRC', 0x04C11DB7, 0xFFFFFFFF, true, true, 0x00000000, 0x340BC6D9)
    /** CRC-32/ISCSI（即 CRC-32C/Castagnoli）：poly=0x1EDC6F41，SSE4.2 有硬件指令。 */
    public static let crc32c = Crc32('CRC-32/ISCSI', 0x1EDC6F41, 0xFFFFFFFF, true, true, 0xFFFFFFFF, 0xE3069283)
    /** CRC-32/KOOPMAN（即 CRC-32K）：poly=0x741B8CD7，Koopman 的低碰撞多项式。 */
    public static let koopman = Crc32('CRC-32/KOOPMAN', 0x741B8CD7, 0xFFFFFFFF, true, true, 0xFFFFFFFF, 0x2D3DD0AE)
    /** CRC-32/BASE91-D：poly=0xA833982B。 */
    public static let base91D = Crc32('CRC-32/BASE91-D', 0xA833982B, 0xFFFFFFFF, true, true, 0xFFFFFFFF, 0x87315576)
    /** CRC-32/AUTOSAR：poly=0xF4ACFB13。 */
    public static let autosar = Crc32('CRC-32/AUTOSAR', 0xF4ACFB13, 0xFFFFFFFF, true, true, 0xFFFFFFFF, 0x1697D06A)
    // ---- 非反射（MSB-first）----
    /** CRC-32/BZIP2（同 AAL5）：非反射，init/xorout 全 1。 */
    public static let bzip2 = Crc32('CRC-32/BZIP2', 0x04C11DB7, 0xFFFFFFFF, false, false, 0xFFFFFFFF, 0xFC891918)
    /** CRC-32/MPEG-2：非反射，init 全 1、xorout=0。 */
    public static let mpeg2 = Crc32('CRC-32/MPEG-2', 0x04C11DB7, 0xFFFFFFFF, false, false, 0x00000000, 0x0376E6E7)
    /** CRC-32/POSIX（即 CKSUM）：非反射，init=0、xorout 全 1（`crc32` 命令行工具的输出）。 */
    public static let posix = Crc32('CRC-32/POSIX', 0x04C11DB7, 0x00000000, false, false, 0xFFFFFFFF, 0x765E7680)
    /** CRC-32/XFER：poly=0x000000AF，init/xorout=0。 */
    public static let xfer = Crc32('CRC-32/XFER', 0x000000AF, 0x00000000, false, false, 0x00000000, 0xBD0BE338)
    /** CRC-32/Q（同 AIXM）：poly=0x814141AB，init/xorout=0，航空数据库用。 */
    public static let q = Crc32('CRC-32/Q', 0x814141AB, 0x00000000, false, false, 0x00000000, 0x3010BF7F)

    /** 全部变体：便于遍历自检与按名字挑选（见 crc_check_test.cj）。 */
    public static let all = [
        isoHdlc, jamcrc, crc32c, koopman, base91D, autosar,
        bzip2, mpeg2, posix, xfer, q
    ]
    private let engine: CrcEngine
    /** RevEng 名称（如 `CRC-32/ISO-HDLC`）。 */
    public let name: String
    /** 该变体对 `"123456789"` 的标准检查值。 */
    public let checkValue: UInt32
    /** `initValue` 即 RevEng catalogue 的 `init`（`init` 是仓颉关键字，故改名）。 */
    public init(name: String, poly: UInt64, initValue: UInt64, refin: Bool, refout: Bool, xorout: UInt64, check: UInt64) {
        this.name = name
        this.engine = CrcEngine(32, poly, initValue, refin, refout, xorout)
        this.checkValue = UInt32(check & 0xFFFFFFFFu64)
    }
    public func initRegister(): UInt32 {
        UInt32(engine.initRegister())
    }
    public func update(crc: UInt32, data: Array<Byte>): UInt32 {
        UInt32(engine.update(UInt64(crc), data))
    }
    public func finish(crc: UInt32): UInt32 {
        UInt32(engine.finish(UInt64(crc)))
    }
    public func compute(data: Array<Byte>): UInt32 {
        UInt32(engine.compute(data))
    }
    public func compute(s: String): UInt32 {
        compute(s.unsafeBytes())
    }
    public func compute<T>(s: T): UInt32 where T <: ToString {
        compute(s.toString().unsafeBytes())
    }
}

// ---- 兼容旧 API：`crc32*` = CRC-32/ISO-HDLC（顶层函数语义不变）----
/** 初始化 CRC 寄存器。 */
@Frozen
public func crc32Init(): UInt32 {
    Crc32.isoHdlc.initRegister()
}
/** 继续累计一段字节。 */
@Frozen
public func crc32Update(crc: UInt32, data: Array<Byte>): UInt32 {
    Crc32.isoHdlc.update(crc, data)
}
/** 收尾：与 FINAL_XOR_VALUE 异或。 */
@Frozen
public func crc32Finish(crc: UInt32): UInt32 {
    Crc32.isoHdlc.finish(crc)
}
/** 一次算完整段（等价 init → update → finish）。 */
@Frozen
public func crc32(data: Array<Byte>): UInt32 {
    Crc32.isoHdlc.compute(data)
}
@Frozen
public func crc32(data: String): UInt32 {
    return crc32(data.unsafeBytes())
}
@Frozen
public func crc32<T>(s: T): UInt32 where T <: ToString {
    crc32(s.toString().unsafeBytes())
}

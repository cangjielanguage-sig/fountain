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
 * CRC-16 各变体（参数口径见 `CrcEngine`，检查值是 `"123456789"` 的 CRC-16）。
 *
 * 用法：
 * ```
 * let c = Crc16.xmodem.compute('123456789')      // 0x31C3
 * let c2 = Crc16.ccittFalse.compute(bytes)
 * ```
 *
 * 注：顶层函数 `crc16(...)` 用**最常用**的 `Crc16.modbus`（CRC-16/MODBUS：poly=0x8005、反射、init=0xFFFF）。
 * 与具体对端互通时请显式挑变体，例如 `Crc16.ccittFalse`（poly=0x1021、init=0xFFFF、非反射、检查值 0x29B1）
 * 或 `Crc16.xmodem`（同族但 init=0x0000）。
 */
public class Crc16 {
    // ---- 非反射（MSB-first）----
    /** CRC-16/XMODEM：poly=0x1021 init=0x0000 xorout=0x0000（顶层 `crc16()` 曾经用过它）。 */
    public static let xmodem = Crc16('CRC-16/XMODEM', 0x1021, 0x0000, false, false, 0x0000, 0x31C3)
    /** CRC-16/CCITT-FALSE（同 IBM-3740）：poly=0x1021 init=0xFFFF xorout=0x0000。 */
    public static let ccittFalse = Crc16('CRC-16/CCITT-FALSE', 0x1021, 0xFFFF, false, false, 0x0000, 0x29B1)
    /** CRC-16/GENIBUS（同 XMODEM 的 init=0xFFFF 且 xorout=0xFFFF 版）。 */
    public static let genibus = Crc16('CRC-16/GENIBUS', 0x1021, 0xFFFF, false, false, 0xFFFF, 0xD64E)
    /** CRC-16/GSM：poly=0x1021 init=0x0000 xorout=0xFFFF。 */
    public static let gsm = Crc16('CRC-16/GSM', 0x1021, 0x0000, false, false, 0xFFFF, 0xCE3C)
    /** CRC-16/PROFIBUS：poly=0x1DCF init=0xFFFF xorout=0xFFFF。 */
    public static let profibus = Crc16('CRC-16/PROFIBUS', 0x1DCF, 0xFFFF, false, false, 0xFFFF, 0xA819)
    /** CRC-16/EN-13757：poly=0x3D65 init=0x0000 xorout=0xFFFF。 */
    public static let en13757 = Crc16('CRC-16/EN-13757', 0x3D65, 0x0000, false, false, 0xFFFF, 0xC2B7)
    /** CRC-16/T10-DIF：poly=0x8BB7 init=0x0000 xorout=0x0000。 */
    public static let t10Dif = Crc16('CRC-16/T10-DIF', 0x8BB7, 0x0000, false, false, 0x0000, 0xD0DB)
    /**
     * 未收录（参数待核对，宁缺勿错）：`CRC-16/A` / `CRC-16/ISO-IEC-14443-3-A`（init=0xC6C6，检查值 0xBF05）。
     * 加它只需一行：确认 `refin/refout` 后写 `Crc16('CRC-16/A', 0x1021, 0xC6C6, ?, ?, 0x0000, 0xBF05)`，
     * 用例会自动核对检查值。
     */
    /** CRC-16/CDMA2000：poly=0xC867 init=0xFFFF xorout=0x0000。 */
    public static let cdma2000 = Crc16('CRC-16/CDMA2000', 0xC867, 0xFFFF, false, false, 0x0000, 0x4C06)
    /** CRC-16/CMS：poly=0x8005 init=0xFFFF xorout=0x0000。 */
    public static let cms = Crc16('CRC-16/CMS', 0x8005, 0xFFFF, false, false, 0x0000, 0xAEE7)
    /** CRC-16/BUYPASS（同 VERIFONE）：poly=0x8005 init=0x0000 xorout=0x0000。 */
    public static let buypass = Crc16('CRC-16/BUYPASS', 0x8005, 0x0000, false, false, 0x0000, 0xFEE8)
    /** CRC-16/DECT-R：poly=0x0589 init=0x0000 xorout=0x0001。 */
    public static let dectR = Crc16('CRC-16/DECT-R', 0x0589, 0x0000, false, false, 0x0001, 0x007E)
    /** CRC-16/DECT-X：poly=0x0589 init=0x0000 xorout=0x0000。 */
    public static let dectX = Crc16('CRC-16/DECT-X', 0x0589, 0x0000, false, false, 0x0000, 0x007F)
    /** CRC-16/TELEDISK：poly=0xA097 init=0x0000 xorout=0x0000。 */
    public static let teledisk = Crc16('CRC-16/TELEDISK', 0xA097, 0x0000, false, false, 0x0000, 0x0FB3)
    /** CRC-16/SPI-FUJITSU（同 AUG-CCITT）：poly=0x1021 init=0x1D0F xorout=0x0000。 */
    public static let spiFujitsu = Crc16('CRC-16/SPI-FUJITSU', 0x1021, 0x1D0F, false, false, 0x0000, 0xE5CC)
    // ---- 反射（LSB-first）----
    /** CRC-16/ARC（同 IBM/CRC-16/LHA）：poly=0x8005 init=0x0000 xorout=0x0000。 */
    public static let arc = Crc16('CRC-16/ARC', 0x8005, 0x0000, true, true, 0x0000, 0xBB3D)
    /** CRC-16/MODBUS：poly=0x8005 init=0xFFFF xorout=0x0000。 */
    public static let modbus = Crc16('CRC-16/MODBUS', 0x8005, 0xFFFF, true, true, 0x0000, 0x4B37)
    /** CRC-16/USB：poly=0x8005 init=0xFFFF xorout=0xFFFF。 */
    public static let usb = Crc16('CRC-16/USB', 0x8005, 0xFFFF, true, true, 0xFFFF, 0xB4C8)
    /** CRC-16/MAXIM-DOW：poly=0x8005 init=0x0000 xorout=0xFFFF。 */
    public static let maximDow = Crc16('CRC-16/MAXIM-DOW', 0x8005, 0x0000, true, true, 0xFFFF, 0x44C2)
    /** CRC-16/KERMIT（同 CRC-16/BLUETOOTH）：poly=0x1021 init=0x0000 xorout=0x0000。 */
    public static let kermit = Crc16('CRC-16/KERMIT', 0x1021, 0x0000, true, true, 0x0000, 0x2189)
    /** CRC-16/X-25：poly=0x1021 init=0xFFFF xorout=0xFFFF。 */
    public static let x25 = Crc16('CRC-16/X-25', 0x1021, 0xFFFF, true, true, 0xFFFF, 0x906E)
    /** CRC-16/MCRF4XX：poly=0x1021 init=0xFFFF xorout=0x0000。 */
    public static let mcrf4xx = Crc16('CRC-16/MCRF4XX', 0x1021, 0xFFFF, true, true, 0x0000, 0x6F91)
    /** CRC-16/RIELLO：poly=0x1021 init=0xB2AA xorout=0x0000。 */
    public static let riello = Crc16('CRC-16/RIELLO', 0x1021, 0xB2AA, true, true, 0x0000, 0x63D0)
    /** CRC-16/TMS37157：poly=0x1021 init=0x89EC xorout=0x0000。 */
    public static let tms37157 = Crc16('CRC-16/TMS37157', 0x1021, 0x89EC, true, true, 0x0000, 0x26B1)
    /** CRC-16/DNP：poly=0x3D65 init=0x0000 xorout=0xFFFF。 */
    public static let dnp = Crc16('CRC-16/DNP', 0x3D65, 0x0000, true, true, 0xFFFF, 0xEA82)

    /** 全部变体：便于遍历自检与按名字挑选（见 crc_check_test.cj）。 */
    public static let all = [
        xmodem, ccittFalse, genibus, gsm, profibus, en13757, t10Dif, cdma2000, cms, buypass,
        dectR, dectX, teledisk, spiFujitsu,
        arc, modbus, usb, maximDow, kermit, x25, mcrf4xx, riello, tms37157, dnp
    ]
    private let engine: CrcEngine
    /** RevEng 名称（如 `CRC-16/XMODEM`），便于日志与自检报告。 */
    public let name: String
    /** 该变体对 `"123456789"` 的标准检查值。 */
    public let checkValue: UInt16
    /** `initValue` 即 RevEng catalogue 的 `init`（`init` 是仓颉关键字，故改名）。 */
    public init(name: String, poly: UInt64, initValue: UInt64, refin: Bool, refout: Bool, xorout: UInt64, check: UInt64) {
        this.name = name
        this.engine = CrcEngine(16, poly, initValue, refin, refout, xorout)
        this.checkValue = UInt16(check & 0xFFFFu64)
    }
    public func initRegister(): UInt16 {
        UInt16(engine.initRegister())
    }
    public func update(crc: UInt16, data: Array<Byte>): UInt16 {
        UInt16(engine.update(UInt64(crc), data))
    }
    public func finish(crc: UInt16): UInt16 {
        UInt16(engine.finish(UInt64(crc)))
    }
    public func compute(data: Array<Byte>): UInt16 {
        UInt16(engine.compute(data))
    }
    public func compute(s: String): UInt16 {
        compute(s.unsafeBytes())
    }
    public func compute<T>(s: T): UInt16 where T <: ToString {
        compute(s.toString().unsafeBytes())
    }
}

// ---- 顶层 API：用最常用的变体（CRC-16/MODBUS）----
@Frozen
public func crc16(bytes: Array<Byte>): UInt16 {
    Crc16.modbus.compute(bytes)
}
@Frozen
public func crc16(s: String): UInt16 {
    Crc16.modbus.compute(s)
}
@Frozen
public func crc16<T>(s: T): UInt16 where T <: ToString {
    Crc16.modbus.compute(s)
}

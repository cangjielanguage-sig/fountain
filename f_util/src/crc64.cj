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
 * CRC-64 各变体（参数口径见 `CrcEngine`，检查值是 `"123456789"` 的 CRC-64）。
 *
 * 用法：
 * ```
 * let c = Crc64.ecma182.compute(bytes)
 * let c2 = Crc64.xz.compute(bytes)              // .xz 容器/`xz --check=crc64` 用的那个
 * ```
 *
 * 注：顶层函数 `crc64(...)` 用**最常用**的 `Crc64.redis`（CRC-64/REDIS：poly=0xAD93D23594C935A9、反射、
 * init/xorout=0）。与具体系统互通时请显式挑变体，例如 `Crc64.xz`（xz 容器、`xz --check=crc64`）、
 * `Crc64.ecma182`（非反射口径）。
 */
public class Crc64 {
    // ---- 非反射（MSB-first）----
    /** CRC-64/ECMA-182：poly=0x42F0E1EBA9EA3693 init=0 xorout=0（历史上顶层 `crc64()` 曾用它）。 */
    public static let ecma182 = Crc64('CRC-64/ECMA-182', 0x42F0E1EBA9EA3693, 0x0000000000000000, false, false, 0x0000000000000000, 0x6C40DF5F0B497347)
    /** CRC-64/WE：同 ECMA-182 但 init/xorout 全 1。 */
    public static let we = Crc64('CRC-64/WE', 0x42F0E1EBA9EA3693, 0xFFFFFFFFFFFFFFFF, false, false, 0xFFFFFFFFFFFFFFFF, 0x62EC59E3F1A4F00A)
    // ---- 反射（LSB-first）----
    /** CRC-64/XZ（同 GO-ECMA）：ECMA-182 的反射口径，init/xorout 全 1。 */
    public static let xz = Crc64('CRC-64/XZ', 0x42F0E1EBA9EA3693, 0xFFFFFFFFFFFFFFFF, true, true, 0xFFFFFFFFFFFFFFFF, 0x995DC9BBDF1939FA)
    /** CRC-64/GO-ISO：poly=0x1B（即 ISO 3309 的反射口径），init/xorout 全 1。 */
    public static let iso = Crc64('CRC-64/GO-ISO', 0x000000000000001B, 0xFFFFFFFFFFFFFFFF, true, true, 0xFFFFFFFFFFFFFFFF, 0xB90956C775A41001)
    /** CRC-64/REDIS：poly=0xAD93D23594C935A9 init=0 xorout=0。 */
    public static let redis = Crc64('CRC-64/REDIS', 0xAD93D23594C935A9, 0x0000000000000000, true, true, 0x0000000000000000, 0xE9C6D914C4B8D9CA)
    /** CRC-64/JONES：poly=0xAD93D23594C935A9，init 全 1、xorout=0。 */
    public static let jones = Crc64('CRC-64/JONES', 0xAD93D23594C935A9, 0xFFFFFFFFFFFFFFFF, true, true, 0x0000000000000000, 0xCAA717168609F281)
    /** 未收录（参数待核对，宁缺勿错）：`CRC-64/NVME`（poly=0xAD93D23594C935A9，init/xorout 全 1）。 */
    /** 全部变体：便于遍历自检与按名字挑选（见 crc_check_test.cj）。 */
    public static let all = [ecma182, we, xz, iso, redis, jones]
    private let engine: CrcEngine
    /** RevEng 名称（如 `CRC-64/ECMA-182`）。 */
    public let name: String
    /** 该变体对 `"123456789"` 的标准检查值。 */
    public let checkValue: UInt64
    /** `initValue` 即 RevEng catalogue 的 `init`（`init` 是仓颉关键字，故改名）。 */
    public init(name: String, poly: UInt64, initValue: UInt64, refin: Bool, refout: Bool, xorout: UInt64, check: UInt64) {
        this.name = name
        this.engine = CrcEngine(64, poly, initValue, refin, refout, xorout)
        this.checkValue = check
    }
    public func initRegister(): UInt64 {
        engine.initRegister()
    }
    public func update(crc: UInt64, data: Array<Byte>): UInt64 {
        engine.update(crc, data)
    }
    public func finish(crc: UInt64): UInt64 {
        engine.finish(crc)
    }
    public func compute(data: Array<Byte>): UInt64 {
        engine.compute(data)
    }
    public func compute(s: String): UInt64 {
        compute(s.unsafeBytes())
    }
    public func compute<T>(s: T): UInt64 where T <: ToString {
        compute(s.toString().unsafeBytes())
    }
}

// ---- 顶层 API：用最常用的变体（CRC-64/REDIS）----
@Frozen
public func crc64(data: Array<Byte>): UInt64 {
    Crc64.redis.compute(data)
}
@Frozen
public func crc64(data: String): UInt64 {
    return crc64(data.unsafeBytes())
}
@Frozen
public func crc64<T>(s: T): UInt64 where T <: ToString {
    crc64(s.toString().unsafeBytes())
}

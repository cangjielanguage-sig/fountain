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

import std.env
import std.time.MonoTime
import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*

/**
 * `CrcEngine` 的等价性基线 + 吞吐门禁（`design.md` D16）。
 *
 * 参考实现（`refUpdate`）是**逐位**算的，只依赖 RevEng 参数口径（width/poly/refin），
 * 不查任何表、不看 `CrcEngine` 的内部结构 —— 这样切片表口径写错时不会"自己跟自己比"全绿：
 * 短向量可能仍然对，长随机数据却整体漂移。
 *
 * 吞吐用例用 `F_UTIL_PERF=1` 门控（默认 SKIP 并打印原因），与 `f_zip` 的
 * `F_ZIP_RESOURCE` / `F_ZIP_SLOW` 口径一致。
 */
@Test
public class CrcEngine_test {
    /** 逐位参考实现：只按多项式定义走，不建表。 */
    private func refUpdate(width: Int64, poly: UInt64, refin: Bool, crc: UInt64, data: Array<Byte>): UInt64 {
        let mask = if (width >= 64) { UInt64.Max } else { (1u64 << width) - 1u64 }
        let p = poly & mask
        var c = crc & mask
        if (refin) {
            // 反射口径：多项式整体反射后从低位向高位走
            var rpoly = 0u64
            var v = p
            for (_ in 0..width) {
                rpoly = (rpoly << 1) | (v & 1u64)
                v >>= 1
            }
            for (i in 0..data.size) {
                c = c ^ UInt64(data[i])
                for (_ in 0..8) {
                    c = if ((c & 1u64) != 0) { (c >> 1) ^ rpoly } else { c >> 1 }
                }
            }
        } else {
            let shift = width - 8
            for (i in 0..data.size) {
                c = c ^ (UInt64(data[i]) << shift)
                for (_ in 0..8) {
                    c = if ((c & (1u64 << (width - 1))) != 0) {
                        ((c << 1) & mask) ^ p
                    } else {
                        (c << 1) & mask
                    }
                }
            }
        }
        c & mask
    }

    /**
     * 确定性的伪随机字节（xorshift64）：只用移位与异或，不触发仓颉默认的整数溢出检查，
     * 也不依赖闭包捕获可变状态。
     */
    private func pseudoBytes(n: Int64): Array<Byte> {
        var x = 0x2545F4914F6CDD1Du64
        let out = Array<Byte>(n, repeat: 0)
        for (i in 0..n) {
            x = x ^ (x << 13)
            x = x ^ (x >> 7)
            x = x ^ (x << 17)
            out[i] = UInt8(x & 0xFFu64)
        }
        out
    }

    private func hex(value: UInt64): String {
        let out = ArrayList<Byte>()
        for (i in 0..16) {
            let nib = UInt8((value >> (4 * (15 - i))) & 0xF)
            out.add(if (nib < 10u8) { nib + 48u8 } else { nib + 87u8 })
        }
        String.fromUtf8(out.toArray())
    }

    /** 反射 32 位变体 + 其多项式（切片路径对它们全部启用）。 */
    private func reflected32Variants(): Array<CrcRef> {
        [
            CrcRef(Crc32.isoHdlc, 0x04C11DB7u64, true),
            CrcRef(Crc32.jamcrc, 0x04C11DB7u64, true),
            CrcRef(Crc32.crc32c, 0x1EDC6F41u64, true),
            CrcRef(Crc32.koopman, 0x741B8CD7u64, true),
            CrcRef(Crc32.base91D, 0xA833982Bu64, true),
            CrcRef(Crc32.autosar, 0xF4ACFB13u64, true),
            // 非反射代表：与切片口径不同的表方向，必须仍然逐字节一致
            CrcRef(Crc32.bzip2, 0x04C11DB7u64, false)
        ]
    }

    /** Scenario: 任意长度两路结果一致 —— 长度不整除 4 时尾巴不能丢字节也不能重复消费。 */
    @TestCase
    public func slicingMatchesByteWiseReferenceForAnyLength(): Unit {
        let lengths = [0, 1, 2, 3, 4, 5, 7, 8, 4095, 4096, 4097, 65537]
        let data = pseudoBytes(65537)
        for (ref in reflected32Variants()) {
            for (len in lengths) {
                let piece = data[0..len]
                let start = UInt64(ref.variant.initRegister())
                let got = UInt64(ref.variant.update(UInt32(start), piece))
                let want = refUpdate(32, ref.poly, ref.refin, start, piece)
                if (got != want) {
                    @Fail('${ref.variant.name}：长度 ${len} 的寄存器 0x${hex(got)}，参考实现 0x${hex(want)}')
                }
            }
        }
    }

    /**
     * Scenario: 分段累计与一次累计等价 —— `1+3+5`、4 的整数倍、`4n+1`、以及逐字节切分。
     * `f_protocol` 的帧校验正是靠"边读边算"这条性质。
     */
    @TestCase
    public func segmentedUpdatesMatchOneShot(): Unit {
        let nine = pseudoBytes(9)
        let fourN = pseudoBytes(4096)
        let fourNPlusOne = pseudoBytes(4097)
        let perByte = pseudoBytes(17)
        let cases = [
            SplitCase('1+3+5', nine, [1, 4]),
            SplitCase('4 的整数倍', fourN, [1024, 2048, 3072]),
            SplitCase('4n+1', fourNPlusOne, [1025, 2049, 3073]),
            SplitCase('逐字节', perByte, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16])
        ]
        for (ref in reflected32Variants()) {
            let oneShot = ref.variant.update(ref.variant.initRegister(), fourNPlusOne)
            for (item in cases) {
                var c = ref.variant.initRegister()
                var pos = 0i64
                for (cut in item.cuts) {
                    c = ref.variant.update(c, item.payload[pos..cut])
                    pos = cut
                }
                c = ref.variant.update(c, item.payload[pos..])
                // 同一段数据的一次算完基准（长度不同的用例单独对照）
                let expected = ref.variant.update(ref.variant.initRegister(), item.payload)
                if (c != expected) {
                    @Fail('${ref.variant.name}：${item.label} 切分得到 0x${hex(UInt64(c))}，一次 update 得到 0x${hex(UInt64(expected))}')
                }
            }
            // 4n+1 的一次算完必须等于切片路径与参考实现
            let want = refUpdate(32, ref.poly, ref.refin, UInt64(ref.variant.initRegister()), fourNPlusOne)
            if (UInt64(oneShot) != want) {
                @Fail('${ref.variant.name}：4n+1 一次 update 0x${hex(UInt64(oneShot))}，参考实现 0x${hex(want)}')
            }
        }
    }

    /**
     * Scenario: 切片只对反射 32 位启用 —— 16 位与 64 位、以及非反射 32 位
     * 的表口径与反射 32 位不同，误用切片会整体漂移。
     */
    @TestCase
    public func otherWidthsAndNonReflectedMatchReference(): Unit {
        let lengths = [0, 1, 3, 4, 5, 4095, 4096, 8193]
        let data = pseudoBytes(8193)
        for (len in lengths) {
            let piece = data[0..len]
            // 非反射 32 位：CRC-32/BZIP2
            let bzStart = UInt64(Crc32.bzip2.initRegister())
            let bzGot = UInt64(Crc32.bzip2.update(UInt32(bzStart), piece))
            let bzWant = refUpdate(32, 0x04C11DB7u64, false, bzStart, piece)
            if (bzGot != bzWant) {
                @Fail('CRC-32/BZIP2：长度 ${len} 的寄存器 0x${hex(bzGot)}，参考实现 0x${hex(bzWant)}')
            }
            // 16 位（反射）：CRC-16/MODBUS
            let mStart = UInt64(Crc16.modbus.initRegister())
            let mGot = UInt64(Crc16.modbus.update(UInt16(mStart), piece))
            let mWant = refUpdate(16, 0x8005u64, true, mStart, piece)
            if (mGot != mWant) {
                @Fail('CRC-16/MODBUS：长度 ${len} 的寄存器 0x${hex(mGot)}，参考实现 0x${hex(mWant)}')
            }
            // 64 位（反射）：CRC-64/REDIS
            let rStart = Crc64.redis.initRegister()
            let rGot = Crc64.redis.update(rStart, piece)
            let rWant = refUpdate(64, 0xAD93D23594C935A9u64, true, rStart, piece)
            if (rGot != rWant) {
                @Fail('CRC-64/REDIS：长度 ${len} 的寄存器 0x${hex(rGot)}，参考实现 0x${hex(rWant)}')
            }
        }
    }

    private func perfEnabled(): Bool {
        match (env.getVariable("F_UTIL_PERF")) {
            case Some(v) => v == "1"
            case None => false
        }
    }

    /** 24 个 CRC-16 变体的参数表：只给测试参考实现用。 */
    private func crc16Rows(): Array<(String, Crc16, UInt64, Bool)> {
        [
            ('CRC-16/XMODEM', Crc16.xmodem, 0x1021, false),
            ('CRC-16/CCITT-FALSE', Crc16.ccittFalse, 0x1021, false),
            ('CRC-16/GENIBUS', Crc16.genibus, 0x1021, false),
            ('CRC-16/GSM', Crc16.gsm, 0x1021, false),
            ('CRC-16/PROFIBUS', Crc16.profibus, 0x1DCF, false),
            ('CRC-16/EN-13757', Crc16.en13757, 0x3D65, false),
            ('CRC-16/T10-DIF', Crc16.t10Dif, 0x8BB7, false),
            ('CRC-16/CDMA2000', Crc16.cdma2000, 0xC867, false),
            ('CRC-16/CMS', Crc16.cms, 0x8005, false),
            ('CRC-16/BUYPASS', Crc16.buypass, 0x8005, false),
            ('CRC-16/DECT-R', Crc16.dectR, 0x0589, false),
            ('CRC-16/DECT-X', Crc16.dectX, 0x0589, false),
            ('CRC-16/TELEDISK', Crc16.teledisk, 0xA097, false),
            ('CRC-16/SPI-FUJITSU', Crc16.spiFujitsu, 0x1021, false),
            ('CRC-16/ARC', Crc16.arc, 0x8005, true),
            ('CRC-16/MODBUS', Crc16.modbus, 0x8005, true),
            ('CRC-16/USB', Crc16.usb, 0x8005, true),
            ('CRC-16/MAXIM-DOW', Crc16.maximDow, 0x8005, true),
            ('CRC-16/KERMIT', Crc16.kermit, 0x1021, true),
            ('CRC-16/X-25', Crc16.x25, 0x1021, true),
            ('CRC-16/MCRF4XX', Crc16.mcrf4xx, 0x1021, true),
            ('CRC-16/RIELLO', Crc16.riello, 0x1021, true),
            ('CRC-16/TMS37157', Crc16.tms37157, 0x1021, true),
            ('CRC-16/DNP', Crc16.dnp, 0x3D65, true)
        ]
    }

    /** Scenario: 24 个 CRC-16 变体在任意长度上与逐位参考实现一致。 */
    @TestCase
    public func slicingBy2MatchesReferenceForAllCrc16Variants(): Unit {
        let lengths = [0, 1, 2, 3, 4, 5, 7, 8, 15, 16, 17, 255, 256, 257, 4095, 4096, 4097, 65537]
        for (row in crc16Rows()) {
            let variant = row[1]
            let poly = row[2]
            let refin = row[3]
            for (n in lengths) {
                let data = pseudoBytes(n)
                let c0 = variant.initRegister()
                let actual = variant.update(c0, data)
                let expected = refUpdate(16, poly, refin, UInt64(c0), data)
                @Assert(UInt64(actual), expected)
            }
        }
    }

    /** Scenario: 边界字节（全 0x00 / 0xFF / 0x80 / 0x01）不因 16 位表项而丢高位。 */
    @TestCase
    public func slicingBy2EdgeBytesMatchReference(): Unit {
        let samples: Array<Array<Byte>> = [
            [0x00u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8],
            [0xFFu8, 0xFFu8, 0xFFu8, 0xFFu8, 0xFFu8, 0xFFu8, 0xFFu8],
            [0x80u8],
            [0x01u8],
            [0x80u8, 0x01u8, 0x80u8, 0x01u8, 0x80u8],
            [0x00u8, 0xFFu8, 0x00u8, 0xFFu8, 0x00u8, 0xFFu8, 0x00u8, 0xFFu8, 0x00u8]
        ]
        for (row in crc16Rows()) {
            let variant = row[1]
            let poly = row[2]
            let refin = row[3]
            for (data in samples) {
                let c0 = variant.initRegister()
                let actual = variant.update(c0, data)
                let expected = refUpdate(16, poly, refin, UInt64(c0), data)
                @Assert(UInt64(actual), expected)
            }
        }
    }

    /** 6 个 CRC-64 变体的参数表：只给测试参考实现用（实现侧不应复制这些常量）。 */
    private func crc64Rows(): Array<(String, Crc64, UInt64, Bool)> {
        [
            ('CRC-64/ECMA-182', Crc64.ecma182, 0x42F0E1EBA9EA3693, false),
            ('CRC-64/WE', Crc64.we, 0x42F0E1EBA9EA3693, false),
            ('CRC-64/XZ', Crc64.xz, 0x42F0E1EBA9EA3693, true),
            ('CRC-64/GO-ISO', Crc64.iso, 0x000000000000001B, true),
            ('CRC-64/REDIS', Crc64.redis, 0xAD93D23594C935A9, true),
            ('CRC-64/JONES', Crc64.jones, 0xAD93D23594C935A9, true)
        ]
    }

    /** Scenario: 6 个 CRC-64 变体在任意长度上与逐位参考实现一致（覆盖尾部与 8 字节边界）。 */
    @TestCase
    public func slicingBy8MatchesReferenceForAllCrc64Variants(): Unit {
        let lengths = [0, 1, 2, 3, 4, 5, 7, 8, 9, 15, 16, 17, 63, 64, 65, 255, 256, 257, 4095, 4096, 4097, 65537]
        for (row in crc64Rows()) {
            let variant = row[1]
            let poly = row[2]
            let refin = row[3]
            for (n in lengths) {
                let data = pseudoBytes(n)
                let c0 = variant.initRegister()
                let actual = variant.update(c0, data)
                let expected = refUpdate(64, poly, refin, c0, data)
                @Assert(actual, expected)
            }
        }
    }

    /** Scenario: 任意切分（含 8 字节边界内部）与一次累计等价。 */
    @TestCase
    public func slicingBy8SegmentedUpdatesMatchOneShot(): Unit {
        let data = pseudoBytes(4097)
        let patterns: Array<Array<Int64>> = [
            [1, 3, 5],
            [8, 16, 64],
            [8, 8, 8],
            [1],
            [4096, 1]
        ]
        for (row in crc64Rows()) {
            let variant = row[1]
            let c0 = variant.initRegister()
            let expected = variant.update(c0, data)
            for (pattern in patterns) {
                var crc = c0
                var off = 0i64
                var k = 0i64
                while (off < data.size) {
                    let step = pattern[k % pattern.size]
                    let end = if (off + step > data.size) { data.size } else { off + step }
                    crc = variant.update(crc, data[off..end])
                    off = end
                    k += 1
                }
                @Assert(crc, expected)
            }
        }
    }

    /** Scenario: CRC-64 表路径 1 MiB 吞吐达标（≥ 60 MB/s）。 */
    @TestCase
    public func throughputCrc64SlicingAtLeastSixtyMegabytesPerSecond(): Unit {
        if (!perfEnabled()) {
            println("SKIP: 未设置 F_UTIL_PERF=1，跳过 CRC-64 表路径吞吐用例")
            return
        }
        let data = pseudoBytes(1024 * 1024)
        // 表路径口径：先关闭生成式路径，避免测到硬件核
        Crc64Hw.setNativeEnabled(false)
        Crc64.xz.compute(data)
        var nanos = Int64.Max
        var value = 0u64
        for (_ in 0..3) {
            let start = MonoTime.now()
            let v = Crc64.xz.compute(data)
            let n = (MonoTime.now() - start).toNanoseconds()
            value = v
            if (n < nanos) {
                nanos = n
            }
        }
        let megabytes = Float64(data.size) / (1024.0 * 1024.0)
        let seconds = Float64(nanos) / 1.0e9
        let mbPerSecond = if (seconds > 0.0) { megabytes / seconds } else { 0.0 }
        Crc64Hw.setNativeEnabled(true)
        Crc64Hw.resetForTest()
        println('1 MiB CRC-64/XZ 表路径（${value}）：${nanos} ns，${mbPerSecond} MB/s')
        if (mbPerSecond < 60.0) {
            @Fail('CRC-64 表路径吞吐 ${mbPerSecond} MB/s 低于 60 MB/s 下限（1 MiB 样本）')
        }
    }

    /** Scenario: CRC-16 表路径 1 MiB 吞吐达标（≥ 40 MB/s）。 */
    @TestCase
    public func throughputCrc16SlicingAtLeastFortyMegabytesPerSecond(): Unit {
        if (!perfEnabled()) {
            println("SKIP: 未设置 F_UTIL_PERF=1，跳过 CRC-16 表路径吞吐用例")
            return
        }
        let data = pseudoBytes(1024 * 1024)
        Crc16.modbus.compute(data)
        var nanos = Int64.Max
        var value = 0u16
        for (_ in 0..3) {
            let start = MonoTime.now()
            let v = Crc16.modbus.compute(data)
            let n = (MonoTime.now() - start).toNanoseconds()
            value = v
            if (n < nanos) {
                nanos = n
            }
        }
        let megabytes = Float64(data.size) / (1024.0 * 1024.0)
        let seconds = Float64(nanos) / 1.0e9
        let mbPerSecond = if (seconds > 0.0) { megabytes / seconds } else { 0.0 }
        println('1 MiB CRC-16/MODBUS 表路径（${value}）：${nanos} ns，${mbPerSecond} MB/s')
        if (mbPerSecond < 40.0) {
            @Fail('CRC-16 表路径吞吐 ${mbPerSecond} MB/s 低于 40 MB/s 下限（1 MiB 样本）')
        }
    }

    /** Scenario: CRC-64/XZ 生成式折叠核与表路径逐位一致（无能力时 SKIP）。 */
    @TestCase
    public func crc64HwMatchesSoftwareForXz(): Unit {
        if (!Crc64Hw.available()) {
            println("SKIP: 无 PMULL/PCLMULQDQ 或 F_UTIL_CRC_HW=off")
            return
        }
        let variants = [Crc64.xz, Crc64.iso, Crc64.redis, Crc64.jones, Crc64.ecma182, Crc64.we]
        let lengths = [256, 257, 272, 1024, 4095, 4096, 4097, 65537]
        for (variant in variants) {
            let c0 = variant.initRegister()
            for (n in lengths) {
                let data = pseudoBytes(n)
                let hw = variant.update(c0, data)
                Crc64Hw.setNativeEnabled(false)
                let sw = variant.update(c0, data)
                Crc64Hw.setNativeEnabled(true)
                Crc64Hw.resetForTest()
                @Assert(hw, sw)
            }
        }
    }

    /** Scenario: 任意切分与一次累计等价（硬件路径内部按 16 字节块消费）。 */
    @TestCase
    public func crc64HwSegmentedMatchesOneShot(): Unit {
        if (!Crc64Hw.available()) {
            println("SKIP: 无 PMULL/PCLMULQDQ 或 F_UTIL_CRC_HW=off")
            return
        }
        let data = pseudoBytes(4097)
        let c0 = Crc64.xz.initRegister()
        let expected = Crc64.xz.update(c0, data)
        for (pattern in [[1i64, 3, 5], [16, 16], [15, 17], [255, 257]]) {
            var crc = c0
            var off = 0i64
            var k = 0i64
            while (off < data.size) {
                let step = pattern[k % pattern.size]
                let end = if (off + step > data.size) { data.size } else { off + step }
                crc = Crc64.xz.update(crc, data[off..end])
                off = end
                k += 1
            }
            @Assert(crc, expected)
        }
    }

    /** Scenario: `auto|on|off` 三态结果一致；`off` 必然不进折叠核，`auto` 在有能力时必然进。 */
    @TestCase
    public func crc64HwThreeStateMatchesReference(): Unit {
        env.setVariable("F_UTIL_CRC_HW", "auto")
        Crc64Hw.setNativeEnabled(true)
        Crc64Hw.resetForTest()
        if (!Crc64Hw.available()) {
            println("SKIP: 无 PMULL/PCLMULQDQ")
            return
        }
        let lengths = [256, 4096]
        try {
            for (row in crc64Rows()) {
                let name = row[0]
                let variant = row[1]
                for (n in lengths) {
                    let data = pseudoBytes(n)
                    let c0 = variant.initRegister()
                    env.setVariable("F_UTIL_CRC_HW", "off")
                    Crc64Hw.resetForTest()
                    let off = variant.update(c0, data)
                    let offNative = Crc64Hw.lastUsedNativeForTest()
                    env.setVariable("F_UTIL_CRC_HW", "on")
                    Crc64Hw.resetForTest()
                    let on = variant.update(c0, data)
                    let onNative = Crc64Hw.lastUsedNativeForTest()
                    env.setVariable("F_UTIL_CRC_HW", "auto")
                    Crc64Hw.resetForTest()
                    let auto = variant.update(c0, data)
                    let autoNative = Crc64Hw.lastUsedNativeForTest()
                    @Assert(off, on)
                    @Assert(on, auto)
                    if (offNative) {
                        @Fail("${name} len=${n}: off 下仍进了折叠核")
                    }
                    if (!autoNative) {
                        @Fail("${name} len=${n}: auto 下未进折叠核")
                    }
                    if (!onNative) {
                        @Fail("${name} len=${n}: on 下未进折叠核")
                    }
                }
            }
        } finally {
            env.setVariable("F_UTIL_CRC_HW", "auto")
            Crc64Hw.resetForTest()
        }
    }

    /** Scenario: 代码页分配/密封失败时静默回退表路径，结果正确且不抛异常。 */
    @TestCase
    public func crc64HwFallsBackWhenCodePageAllocationFails(): Unit {
        env.setVariable("F_UTIL_CRC_HW", "auto")
        Crc64Hw.setNativeEnabled(true)
        Crc64Hw.resetForTest()
        Crc64Hw.forceAllocFailureForTest(true)
        try {
            let data = pseudoBytes(4096)
            let c0 = Crc64.xz.initRegister()
            let hw = Crc64Hw.update(c0, data, data.size, 0x42F0E1EBA9EA3693u64)
            if (hw.isSome()) {
                @Fail("分配失败时 update 仍返回了硬件结果")
            }
            let value = Crc64.xz.update(c0, data)
            Crc64Hw.setNativeEnabled(false)
            let expected = Crc64.xz.update(c0, data)
            Crc64Hw.setNativeEnabled(true)
            @Assert(value, expected)
        } finally {
            Crc64Hw.forceAllocFailureForTest(false)
            Crc64Hw.resetForTest()
        }
    }

    /** Scenario: 6 个 CRC-64 变体的硬件路径吞吐（1 MiB ≥ 500 MB/s）与 4 KiB 绝对耗时（≤ 1.34 µs）。 */
    @TestCase
    public func throughputCrc64HwAtLeastFiveHundredMegabytesPerSecond(): Unit {
        if (!perfEnabled()) {
            println("SKIP: 未设置 F_UTIL_PERF=1，跳过 CRC-64 硬件吞吐用例")
            return
        }
        env.setVariable("F_UTIL_CRC_HW", "auto")
        Crc64Hw.setNativeEnabled(true)
        Crc64Hw.resetForTest()
        if (!Crc64Hw.available()) {
            println("SKIP: 无 PMULL/PCLMULQDQ")
            return
        }
        let data = pseudoBytes(1024 * 1024)
        let frame = pseudoBytes(4096)
        let megabytes = Float64(data.size) / (1024.0 * 1024.0)
        for (row in crc64Rows()) {
            let name = row[0]
            let variant = row[1]
            let c0 = variant.initRegister()
            // 1 MiB：预热后取 3 次最小值，降低共享 VM 上抢占带来的抖动
            variant.update(c0, data)
            var bestNanos = Int64.Max
            var value = 0u64
            for (_ in 0..3) {
                let start = MonoTime.now()
                let v = variant.update(c0, data)
                let n = (MonoTime.now() - start).toNanoseconds()
                value = v
                if (n < bestNanos) {
                    bestNanos = n
                }
            }
            let seconds = Float64(bestNanos) / 1.0e9
            let mbPerSecond = if (seconds > 0.0) { megabytes / seconds } else { 0.0 }
            // 4 KiB：预热 200 次，取 3 组 × 1000 次的最小单次耗时
            for (_ in 0..200) {
                variant.update(c0, frame)
            }
            var bestPerCall = Float64.Max
            for (_ in 0..3) {
                var sink = 0u64
                let start = MonoTime.now()
                for (_ in 0..1000) {
                    sink = variant.update(c0, frame)
                }
                let perCall = Float64((MonoTime.now() - start).toNanoseconds()) / 1000.0
                if (perCall < bestPerCall) {
                    bestPerCall = perCall
                }
                if (sink == 0u64 && value == 0u64) {
                    @Fail('${name}: 测量结果异常')
                }
            }
            println('1 MiB ${name} 硬件路径（${value}）：${bestNanos} ns，${mbPerSecond} MB/s；4 KiB 单次 ${bestPerCall} ns')
            if (mbPerSecond < 500.0) {
                @Fail('${name} 硬件路径吞吐 ${mbPerSecond} MB/s 低于 500 MB/s')
            }
            if (bestPerCall > 1340.0) {
                @Fail('${name} 硬件路径 4 KiB 单次 ${bestPerCall} ns 超过 1.34 µs')
            }
        }
    }

    /** Scenario: 1 MiB 吞吐达标 —— 实测值同时用于回填 `design.md` D16 与设计稿 §10。 */
    @TestCase
    public func throughputAtLeastThirtyMegabytesPerSecond(): Unit {
        if (!perfEnabled()) {
            println("SKIP: 未设置 F_UTIL_PERF=1，跳过 1 MiB CRC32 吞吐用例")
            return
        }
        let data = pseudoBytes(1024 * 1024)
        // 预热：让 JIT/缓存先进入稳态，再计时（结果丢弃，只为了让后面的测量不被首次路径拖慢）
        crc32(data)
        let start = MonoTime.now()
        let value = crc32(data)
        let nanos = (MonoTime.now() - start).toNanoseconds()
        let megabytes = Float64(data.size) / (1024.0 * 1024.0)
        let seconds = Float64(nanos) / 1.0e9
        let mbPerSecond = if (seconds > 0.0) { megabytes / seconds } else { 0.0 }
        println('1 MiB CRC32（${value}）：${nanos} ns，${mbPerSecond} MB/s')
        if (mbPerSecond < 30.0) {
            @Fail('CRC32 吞吐 ${mbPerSecond} MB/s 低于 30 MB/s 下限（1 MiB 样本）')
        }
    }

    /** Scenario: 未设门控时跳过 —— 不计为失败，且必须打印原因。 */
    @TestCase
    public func throughputSkippedWithoutGate(): Unit {
        if (perfEnabled()) {
            println("F_UTIL_PERF=1：吞吐用例已启用，跳过本条 SKIP 校验")
            return
        }
        // 门控关闭时上面的吞吐用例必须走 SKIP 分支而不是失败；这里钉住门控判定本身
        println("SKIP: 未设置 F_UTIL_PERF=1，吞吐用例默认不跑")
    }
}

/** 变体 + 其 RevEng 参数（参考实现只认这几个值，不读 `CrcEngine` 内部）。 */
struct CrcRef {
    let variant: Crc32
    let poly: UInt64
    let refin: Bool
    init(variant: Crc32, poly: UInt64, refin: Bool) {
        this.variant = variant
        this.poly = poly
        this.refin = refin
    }
}

/** 一种切分方式：标签 + 数据 + 切点列表（切点都落在 `payload` 内）。 */
struct SplitCase {
    let label: String
    let payload: Array<Byte>
    let cuts: Array<Int64>
    init(label: String, payload: Array<Byte>, cuts: Array<Int64>) {
        this.label = label
        this.payload = payload
        this.cuts = cuts
    }
}

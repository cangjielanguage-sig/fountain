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
import fountain::f_base.*
import std.unittest.*
import std.unittest.testmacro.*

/**
 * CRC 自检：**每个变体都带 RevEng 标准检查值**（`"123456789"` 的 CRC），逐个核对。
 * 用途：钉住参数（多项式/初值/反射/异或），避免"名字是某个标准、算出来却是另一套"而不被察觉；
 * 新加变体只要在 `CrcXX.all` 里带上正确的 `check` 就会被自动覆盖。
 *
 * 同时验证：顶层函数（`crc16`/`crc32`/`crc64`/`crc32Init`/`crc32Update`/`crc32Finish`）指向的变体 ——
 * 最常用的 MODBUS / ISO-HDLC / REDIS（`crc32*` 系列 = ISO-HDLC，f_protocol 帧校验与 f_store WAL 用它），
 * 以及**增量接口与一次算完等价**（帧要边写边算）。
 */
@Test
public class Crc_check_test {
    private let check: Array<Byte> = '123456789'.unsafeBytes()
    private let empty: Array<Byte> = []

    /** 十六进制打印（仓颉整数 toString 是十进制，报表里看十六进制更直观）。 */
    private func hex(value: UInt64, width: Int64): String {
        let out = ArrayList<Byte>()
        for (i in 0..width) {
            let nib = UInt8((value >> (4 * (width - 1 - i))) & 0xF)
            out.add(if (nib < 10u8) { nib + 48u8 } else { nib + 87u8 })
        }
        String.fromUtf8(out.toArray())
    }

    /** 顶层 API 用最常用变体：`crc16`=MODBUS、`crc32`=ISO-HDLC、`crc64`=REDIS。 */
    @TestCase
    public func topLevelFuncsUseMostCommonVariants(): Unit {
        @Assert(crc16(check), 0x4B37u16)
        @Assert(crc16(empty), 0xFFFFu16)                   // MODBUS：init 全 1、xorout=0
        @Assert(crc32(check), 0xCBF43926u32)
        @Assert(crc32(empty), 0x00000000u32)
        @Assert(crc64(check), 0xE9C6D914C4B8D9CAu64)
        @Assert(crc64(empty), 0x0000000000000000u64)
        // 泛型/字符串重载必须返回各自位宽的同值（历史上出过"返回 UInt16 却叫 crc64"的复制粘贴 bug）
        @Assert(crc16('123456789'), 0x4B37u16)
        @Assert(crc32('123456789'), 0xCBF43926u32)
        @Assert(crc64('123456789'), 0xE9C6D914C4B8D9CAu64)
    }

    /** 顶层 API 必须等于其对应的变体（包装层没走样）。 */
    @TestCase
    public func topLevelFuncsMatchVariants(): Unit {
        @Assert(crc16(check), Crc16.modbus.compute(check))
        @Assert(crc32(check), Crc32.isoHdlc.compute(check))
        @Assert(crc64(check), Crc64.redis.compute(check))
        @Assert(crc32Init(), Crc32.isoHdlc.initRegister())
        @Assert(crc32Finish(0u32), Crc32.isoHdlc.finish(0u32))
        @Assert(crc32Update(0u32, empty), 0u32)
    }

    /** CRC-16 全变体按 catalog 检查值自检。 */
    @TestCase
    public func crc16VariantsMatchCatalogue(): Unit {
        for (v in Crc16.all) {
            let got = v.compute(check)
            if (got != v.checkValue) {
                @Fail('${v.name}: crc16("123456789") = 0x${hex(UInt64(got), 4)}, 期望 0x${hex(UInt64(v.checkValue), 4)}')
            }
        }
    }

    /** CRC-32 全变体按 catalog 检查值自检。 */
    @TestCase
    public func crc32VariantsMatchCatalogue(): Unit {
        for (v in Crc32.all) {
            let got = v.compute(check)
            if (got != v.checkValue) {
                @Fail('${v.name}: crc32("123456789") = 0x${hex(UInt64(got), 8)}, 期望 0x${hex(UInt64(v.checkValue), 8)}')
            }
        }
    }

    /** CRC-64 全变体按 catalog 检查值自检。 */
    @TestCase
    public func crc64VariantsMatchCatalogue(): Unit {
        for (v in Crc64.all) {
            let got = v.compute(check)
            if (got != v.checkValue) {
                @Fail('${v.name}: crc64("123456789") = 0x${hex(got, 16)}, 期望 0x${hex(v.checkValue, 16)}')
            }
        }
    }

    /** 增量（init → update → update → finish）必须等于一次算完 —— 分片/短读短写都不能改变结果。 */
    @TestCase
    public func incrementalEqualsOneShot(): Unit {
        let payload = Array<Byte>(1777) {i => UInt8((i * 31 + 7) % 251)}
        let head = payload[0..1000]
        let tail = payload[1000..]
        for (v in Crc16.all) {
            let pieces = v.finish(v.update(v.update(v.initRegister(), head), tail))
            if (pieces != v.compute(payload)) {
                @Fail('${v.name}: 增量 0x${hex(UInt64(pieces), 4)} != 一次算完 0x${hex(UInt64(v.compute(payload)), 4)}')
            }
        }
        for (v in Crc32.all) {
            let pieces = v.finish(v.update(v.update(v.initRegister(), head), tail))
            if (pieces != v.compute(payload)) {
                @Fail('${v.name}: 增量 0x${hex(UInt64(pieces), 8)} != 一次算完 0x${hex(UInt64(v.compute(payload)), 8)}')
            }
        }
        for (v in Crc64.all) {
            let pieces = v.finish(v.update(v.update(v.initRegister(), head), tail))
            if (pieces != v.compute(payload)) {
                @Fail('${v.name}: 增量 0x${hex(pieces, 16)} != 一次算完 0x${hex(v.compute(payload), 16)}')
            }
        }
    }

    /** 空输入：一次算完必须等于"初值直接收尾"（反射/非反射变体都不能例外）。 */
    @TestCase
    public func emptyInputEqualsFinishOfInit(): Unit {
        for (v in Crc16.all) {
            @Assert(v.compute(empty), v.finish(v.initRegister()))
        }
        for (v in Crc32.all) {
            @Assert(v.compute(empty), v.finish(v.initRegister()))
        }
        for (v in Crc64.all) {
            @Assert(v.compute(empty), v.finish(v.initRegister()))
        }
    }
}

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
import std.unittest.*
import std.unittest.testmacro.*

/**
 * CRC 的**标准检查值**（CRC catalogue，输入 "123456789"）。
 * 用途：钉住算法参数，避免"名字是某个标准、算出来却是另一套"而不被察觉。
 *
 * | 函数 | 变体与参数 | 检查值 |
 * | --- | --- | --- |
 * | `crc16` | CRC-16/XMODEM：poly=0x1021, init=0, xorout=0, 非反射 | 0x31C3 |
 * | `crc32` | CRC-32/IEEE（zlib/gzip/PNG）：poly=0xEDB88320, init/xorout=全 1, 反射 | 0xCBF43926 |
 * | `crc64` | CRC-64/ECMA-182：poly=0x42F0E1EBA9EA3693, init=0, xorout=0, 非反射 | 0x6C40DF5F0B497347 |
 */
@Test
public class Crc_check_test {
    private let check: Array<Byte> = '123456789'.unsafeBytes()
    private let empty: Array<Byte> = []

    /** 与实际使用一致的：CRC-16/XMODEM。 */
    @TestCase
    public func crc16MatchesStandard(): Unit {
        @Assert(crc16(check), 0x31C3u16)
        @Assert(crc16(empty), 0x0000u16)
    }

    /** 标准 CRC-32（IEEE 802.3）；`f_store` 的 WAL 记录校验用的就是它。 */
    @TestCase
    public func crc32MatchesStandard(): Unit {
        @Assert(crc32(check), 0xCBF43926u32)
        @Assert(crc32(empty), 0x00000000u32)
    }

    /** 标准 CRC-64/ECMA-182（修复前算出来是 0x4db9a9f87ec10c59，两套标准都对不上）。 */
    @TestCase
    public func crc64MatchesStandard(): Unit {
        @Assert(crc64(check), 0x6C40DF5F0B497347u64)
        @Assert(crc64(empty), 0x0000000000000000u64)
    }

    /** 泛型重载必须返回各自位宽的同值（修复前返回的是 crc16 的 16 位结果）。 */
    @TestCase
    public func genericOverloadsReturnOwnWidth(): Unit {
        @Assert(crc16('123456789'.unsafeBytes()), 0x31C3u16)
        @Assert(crc32('123456789'), 0xCBF43926u32)
        @Assert(crc64('123456789'), 0x6C40DF5F0B497347u64)
    }
}

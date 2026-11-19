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
package fountain::f_zip

import fountain::f_io.ByteBuffer
import std.unittest.*
import std.unittest.testmacro.*

@Test
public class ZipLayout_test {
    /** 三个签名 + ZIP64 两个签名的数值与字节序。 */
    @TestCase
    public func signatureValues(): Unit {
        @Assert(ZipLayout.SIGNATURE_LOCAL, 0x04034b50u32)
        @Assert(ZipLayout.SIGNATURE_CENTRAL, 0x02014b50u32)
        @Assert(ZipLayout.SIGNATURE_EOCD, 0x06054b50u32)
        @Assert(ZipLayout.SIGNATURE_EOCD64, 0x06064b50u32)
        @Assert(ZipLayout.SIGNATURE_EOCD64_LOCATOR, 0x07064b50u32)
        @Assert(ZipLayout.SIGNATURE_DATA_DESCRIPTOR, 0x08074b50u32)

        // 小端：0x06054b50 落成 50 4B 05 06
        let out = ByteBuffer()
        writeU32LE(out, ZipLayout.SIGNATURE_EOCD)
        let b = out.bytes()
        @Assert(b[0], 0x50u8)
        @Assert(b[1], 0x4Bu8)
        @Assert(b[2], 0x05u8)
        @Assert(b[3], 0x06u8)
    }

    @TestCase
    public func fixedSizes(): Unit {
        @Assert(ZipLayout.LOCAL_HEADER_SIZE, 30)
        @Assert(ZipLayout.CENTRAL_HEADER_SIZE, 46)
        @Assert(ZipLayout.EOCD_SIZE, 22)
        @Assert(ZipLayout.EOCD64_SIZE, 56)
        @Assert(ZipLayout.EOCD64_LOCATOR_SIZE, 20)
        @Assert(ZipLayout.DATA_DESCRIPTOR_SIZE, 24)
        @Assert(ZipLayout.EOCD_WINDOW_LIMIT, 22 + 65535)
    }

    @TestCase
    public func zip64Constants(): Unit {
        @Assert(ZipLayout.ZIP64_EXTRA_ID, 0x0001u16)
        @Assert(ZipLayout.SENTINEL_U16, 0xFFFFu16)
        @Assert(ZipLayout.SENTINEL_U32, 0xFFFFFFFFu32)
        @Assert(ZipLayout.VERSION_ZIP64, 45u16)
        @Assert(ZipLayout.VERSION_DEFAULT, 20u16)
        @Assert(CompressionMethod.Stored.value, 0u16)
        @Assert(CompressionMethod.Deflate.value, 8u16)
        @Assert(CompressionMethod.fromValue(12).isNone(), true)
        @Assert(CompressionMethod.fromValue(8).getOrThrow().value, 8u16)
    }
}

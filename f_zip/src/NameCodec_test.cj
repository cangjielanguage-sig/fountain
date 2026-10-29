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

import std.unittest.*
import std.unittest.testmacro.*

@Test
public class NameCodec_test {
    /** 场景「纯 ASCII 名不置位 bit 11」。 */
    @TestCase
    public func asciiNameHasNoUtf8Flag(): Unit {
        let (bytes, utf8) = encodeName("a/b.txt")
        @Assert(utf8, false)
        @Assert(String.fromUtf8(bytes), "a/b.txt")
    }

    /** 场景「中文名置位 bit 11」。 */
    @TestCase
    public func chineseNameSetsUtf8Flag(): Unit {
        let (bytes, utf8) = encodeName("中文.txt")
        @Assert(utf8, true)
        @Assert(String.fromUtf8(bytes), "中文.txt")
    }

    /** 场景「未置位 bit 11 的合法 UTF-8 名」。 */
    @TestCase
    public func utf8WithoutFlag(): Unit {
        let bytes = "中文.txt".toArray()
        @Assert(decodeName(bytes, false), "中文.txt")
    }

    /** 场景「未置位 bit 11 的 GBK 名」：`中文.txt` 的 GBK 字节。 */
    @TestCase
    public func gbkWithoutFlag(): Unit {
        let bytes: Array<Byte> = [0xD6u8, 0xD0u8, 0xCEu8, 0xC4u8, 0x2Eu8, 0x74u8, 0x78u8, 0x74u8]
        @Assert(decodeName(bytes, false), "中文.txt")
    }

    /** 场景「两种编码都非法」：按 Latin-1 逐字节映射，不抛异常。 */
    @TestCase
    public func invalidBothFallsBackToLatin1(): Unit {
        let bytes: Array<Byte> = [0xFFu8]
        @Assert(decodeName(bytes, false), "ÿ")
    }

    /** bit 11 置位时直接按 UTF-8 解码。 */
    @TestCase
    public func utf8FlagWins(): Unit {
        @Assert(decodeName("中文".toArray(), true), "中文")
    }

    @TestCase
    public func strictUtf8RejectsBadSequences(): Unit {
        @Assert(strictUtf8([0xC3u8]).isNone(), true)                  // 截断
        @Assert(strictUtf8([0xC0u8, 0xAFu8]).isNone(), true)          // 过长编码
        @Assert(strictUtf8([0xEDu8, 0xA0u8, 0x80u8]).isNone(), true)  // 代理区
        @Assert(strictUtf8("中".toArray()).getOrThrow(), "中")
    }
}

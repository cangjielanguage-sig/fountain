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
package fountain::f_xml

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.ArrayList

@Test
public class ByteSniffer_test {
    private func sniffText(bytes: Array<Byte>): SniffResult {
        ByteSniffer.sniff(MemoryInputStream(bytes))
    }

    private func concat(a: Array<Byte>, b: Array<Byte>): Array<Byte> {
        let out = ArrayList<Byte>()
        for (x in a) {
            out.add(x)
        }
        for (x in b) {
            out.add(x)
        }
        out.toArray()
    }

    /** UTF-8 BOM 被识别，且前缀完整保留（含 BOM）。 */
    @TestCase
    public func utf8Bom(): Unit {
        let bom: Array<Byte> = [0xEF, 0xBB, 0xBF]
        let result = sniffText(concat(bom, "<a>x</a>".toArray()))
        @Assert(match (result.encoding) {
            case DetectedEncoding.Utf8 => true
            case _ => false
        })
        @Assert(result.bomLength == 3)
        @Assert(result.prefix[0] == 0xEF && result.prefix[1] == 0xBB && result.prefix[2] == 0xBF)
    }

    @TestCase
    public func utf16leBom(): Unit {
        let result = sniffText(utf16leBytes("<a>x</a>", withBom: true))
        @Assert(match (result.encoding) {
            case DetectedEncoding.Utf16Le => true
            case _ => false
        })
        @Assert(result.bomLength == 2)
    }

    @TestCase
    public func utf16beBom(): Unit {
        let bytes: Array<Byte> = [0xFE, 0xFF, 0x00, 0x3C]
        let result = sniffText(bytes)
        @Assert(match (result.encoding) {
            case DetectedEncoding.Utf16Be => true
            case _ => false
        })
        @Assert(result.bomLength == 2)
    }

    /** 4 字节 BOM 优先于 2 字节 BOM。 */
    @TestCase
    public func utf32leBeatsUtf16le(): Unit {
        let bytes: Array<Byte> = [0xFF, 0xFE, 0x00, 0x00, 0x3C, 0x00, 0x00, 0x00]
        let result = sniffText(bytes)
        @Assert(match (result.encoding) {
            case DetectedEncoding.Utf32Le => true
            case _ => false
        })
        @Assert(result.bomLength == 4)
    }

    /** 无 BOM 的 UTF-16LE 魔数。 */
    @TestCase
    public func utf16leMagic(): Unit {
        let bytes: Array<Byte> = [0x3C, 0x00, 0x3F, 0x00]
        let result = sniffText(bytes)
        @Assert(match (result.encoding) {
            case DetectedEncoding.Utf16Le => true
            case _ => false
        })
        @Assert(result.bomLength == 0)
    }

    /** 无 BOM 的 UTF-16BE 魔数。 */
    @TestCase
    public func utf16beMagic(): Unit {
        let bytes: Array<Byte> = [0x00, 0x3C, 0x00, 0x3F]
        let result = sniffText(bytes)
        @Assert(match (result.encoding) {
            case DetectedEncoding.Utf16Be => true
            case _ => false
        })
    }

    /** 声明双引号。 */
    @TestCase
    public func declaredDoubleQuoted(): Unit {
        let result = sniffText("<?xml version=\"1.0\" encoding=\"GBK\"?><a/>".toArray())
        @Assert(match (result.encoding) {
            case DetectedEncoding.Other(cs) => cs.nameEquals("GBK")
            case _ => false
        })
    }

    /** 声明单引号。 */
    @TestCase
    public func declaredSingleQuoted(): Unit {
        let result = sniffText("<?xml version='1.0' encoding='GBK'?><a/>".toArray())
        @Assert(match (result.encoding) {
            case DetectedEncoding.Other(cs) => cs.nameEquals("GBK")
            case _ => false
        })
    }

    /** BOM 与声明冲突以 BOM 为准，且不报错。 */
    @TestCase
    public func bomWinsOverDeclaration(): Unit {
        let bom: Array<Byte> = [0xEF, 0xBB, 0xBF]
        let body = "<?xml version=\"1.0\" encoding=\"GBK\"?><a>中</a>".toArray()
        let result = sniffText(concat(bom, body))
        @Assert(match (result.encoding) {
            case DetectedEncoding.Utf8 => true
            case _ => false
        })
    }

    /** 没有任何线索时默认 UTF-8。 */
    @TestCase
    public func defaultsToUtf8(): Unit {
        let result = sniffText("<a/>".toArray())
        @Assert(match (result.encoding) {
            case DetectedEncoding.Utf8 => true
            case _ => false
        })
    }

    /** 声明的 `encoding` 大小写不敏感。 */
    @TestCase
    public func declaredEncodingCaseInsensitive(): Unit {
        let result = sniffText("<?xml version=\"1.0\" encoding=\"utf8\"?><a/>".toArray())
        @Assert(match (result.encoding) {
            case DetectedEncoding.Utf8 => true
            case _ => false
        })
    }
}

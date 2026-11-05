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
package fountain::f_svg

import std.unittest.*
import std.unittest.testmacro.*

private let GZIP_TEST_SVG = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20\" height=\"10\">" +
    "<rect width=\"10\" height=\"5\" fill=\"#112233\"/></svg>"

@Test
public class SvgGzip_test {
    /** parseAuto 对纯文本与 gzip 得到同一文档。 */
    @TestCase
    public func parseAutoMatchesText(): Unit {
        let textDocument = SvgParser.parseAuto(GZIP_TEST_SVG.toArray())
        let compressed = writeGzip(SvgParser.parse(GZIP_TEST_SVG))
        let gzipDocument = SvgParser.parseAuto(compressed)
        @Assert(documentSnapshot(textDocument) == documentSnapshot(gzipDocument))
        @Assert(compressed[0] == 0x1F)
        @Assert(compressed[1] == 0x8B)
    }

    /** parseGzip 强制解压，非 gzip 输入抛 Syntax。 */
    @TestCase
    public func parseGzipRejectsPlainText(): Unit {
        let error = expectSvgException({=> SvgParser.parseGzip(GZIP_TEST_SVG.toArray())})
        @Assert(error.kind == SvgErrorKind.Syntax)
    }

    /** 截断与损坏 CRC 均抛 Syntax。 */
    @TestCase
    public func corruptInputsRejected(): Unit {
        let compressed = writeGzip(SvgParser.parse(GZIP_TEST_SVG))
        let truncated = compressed[0..compressed.size - 10]
        let truncatedError = expectSvgException({=> SvgParser.parseGzip(truncated)})
        @Assert(truncatedError.kind == SvgErrorKind.Syntax)

        let corrupted = Array<Byte>(compressed.size, repeat: 0)
        for (index in 0..compressed.size) {
            corrupted[index] = compressed[index]
        }
        corrupted[corrupted.size - 8] = UInt8(Int64(corrupted[corrupted.size - 8]) ^ 0xFF)
        let crcError = expectSvgException({=> SvgParser.parseGzip(corrupted)})
        @Assert(crcError.kind == SvgErrorKind.Syntax)
    }

    /** 解压输出超过上限抛 Limit。 */
    @TestCase
    public func decompressionLimit(): Unit {
        let compressed = writeGzip(SvgParser.parse(GZIP_TEST_SVG))
        let options = SvgParseOptions(security: SvgSecurityOptions(maxDecompressedBytes: 16))
        let error = expectSvgException({=> SvgParser.parseGzip(compressed, options: options)})
        @Assert(error.kind == SvgErrorKind.Limit)
    }

    /** 解压后仍受元素数上限约束。 */
    @TestCase
    public func decompressedStillBounded(): Unit {
        let compressed = writeGzip(SvgParser.parse(GZIP_TEST_SVG))
        let options = SvgParseOptions(security: SvgSecurityOptions(maxElements: 1))
        let error = expectSvgException({=> SvgParser.parseGzip(compressed, options: options)})
        @Assert(error.kind == SvgErrorKind.Limit)
    }

    /** 输出确定性：mtime 为 0，连续两次字节一致。 */
    @TestCase
    public func outputDeterminism(): Unit {
        let document = SvgParser.parse(GZIP_TEST_SVG)
        let first = writeGzip(document)
        let second = writeGzip(document)
        @Assert(first.size == second.size)
        for (index in 0..first.size) {
            @Assert(first[index] == second[index])
        }
        @Assert(first[4] == 0 && first[5] == 0 && first[6] == 0 && first[7] == 0)
    }

    /** gzip 往返。 */
    @TestCase
    public func roundTrip(): Unit {
        let original = SvgParser.parse(GZIP_TEST_SVG)
        let compressed = writeGzip(original)
        let reparsed = SvgParser.parseGzip(compressed)
        @Assert(documentSnapshot(reparsed) == documentSnapshot(original))
    }
}

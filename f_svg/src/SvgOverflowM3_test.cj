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

@Test
public class SvgOverflowM3_test {
    /** 32 位无符号边界乘积不得绕过 PNG 像素上限。 */
    @TestCase
    public func pngDimensionOverflow(): Unit {
        let maximum: Int64 = 0xFFFFFFFF
        let cases: Array<(Int64, Int64)> = [
            (maximum, maximum),
            (maximum, 2),
            (0x80000000, 0x80000000),
            (0x7FFFFFFF, 0x7FFFFFFF)
        ]
        for (dimension in cases) {
            let out = pngPrefix(dimension[0], dimension[1], 8, 6, 0)
            pngChunk(out, "IDAT", Array<Byte>())
            pngChunk(out, "IEND", Array<Byte>())
            let error = expectSvgException({=> SvgPngDecoder.decode(out.bytes())})
            @Assert(error.kind == SvgErrorKind.Limit)
        }
    }

    /** 位图分配前的乘法防溢出。 */
    @TestCase
    public func bitmapAllocationOverflow(): Unit {
        let error = expectSvgException({=> SvgBitmap(3_000_000_000, 3_000_000_000)})
        @Assert(error.kind == SvgErrorKind.Limit)
        let error2 = expectSvgException({=> SvgBitmap(0x7FFFFFFF, 0x7FFFFFFF)})
        @Assert(error2.kind == SvgErrorKind.Limit)
    }

    /** pattern tile 乘法溢出同样抛 Limit。 */
    @TestCase
    public func patternTileOverflow(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"10\">" +
            "<defs><pattern id=\"p\" width=\"6000000000\" height=\"6000000000\" " +
            "patternUnits=\"userSpaceOnUse\"/></defs></svg>"
        )
        let pattern = (document.root.child("defs").getOrThrow().child("pattern")
            .getOrThrow() as SvgPattern).getOrThrow()
        let error = expectSvgException(
            {=>
                SvgPatternSampler(root: Some(document.root)).sample(
                    pattern,
                    SvgBounds(0.0, 0.0, 10.0, 10.0),
                    SvgMatrix.identity,
                    SvgRenderOptions()
                )
            }
        )
        @Assert(error.kind == SvgErrorKind.Limit)
    }
}

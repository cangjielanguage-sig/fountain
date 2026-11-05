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
public class SvgPaint_test {
    /** 四种基本形态。 */
    @TestCase
    public func basicKinds(): Unit {
        @Assert(SvgPaint.parse("none") == SvgPaint.None)
        @Assert(SvgPaint.parse("NONE") == SvgPaint.None)
        @Assert(SvgPaint.parse("currentColor") == SvgPaint.CurrentColor)
        @Assert(SvgPaint.parse("CURRENTCOLOR") == SvgPaint.CurrentColor)
        let red = SvgPaint.parse("red")
        @Assert(red.kind == SvgPaintKind.Color)
        @Assert(red.color == Some(SvgColor.fromRgb(255, 0, 0)))
        @Assert(red.reference.isNone())
        @Assert(red.fallback.isNone())
        @Assert(SvgPaint.parse("#f00") == red)
    }

    /** url() 片段引用，含引号写法。 */
    @TestCase
    public func referenceForms(): Unit {
        let plain = SvgPaint.parse("url(#grad1)")
        @Assert(plain.kind == SvgPaintKind.Reference)
        @Assert(plain.reference == Some("#grad1"))
        @Assert(plain.color.isNone())
        @Assert(plain.fallback.isNone())

        let doubleQuoted = SvgPaint.parse("url(\"#grad1\")")
        @Assert(doubleQuoted.reference == Some("#grad1"))
        let singleQuoted = SvgPaint.parse("url('#grad1')")
        @Assert(singleQuoted.reference == Some("#grad1"))
        let spaced = SvgPaint.parse("  url( #grad1 )  ")
        @Assert(spaced.reference == Some("#grad1"))
    }

    /** 三种 fallback。 */
    @TestCase
    public func fallbacks(): Unit {
        let noneFallback = SvgPaint.parse("url(#grad1) none")
        @Assert(noneFallback.kind == SvgPaintKind.Reference)
        @Assert(noneFallback.fallback == Some(SvgPaint.None))

        let colorFallback = SvgPaint.parse("url(#grad1) red")
        @Assert(colorFallback.fallback == Some(SvgPaint.of(SvgColor.fromRgb(255, 0, 0))))

        let currentFallback = SvgPaint.parse("url(#grad1) currentColor")
        @Assert(currentFallback.fallback == Some(SvgPaint.CurrentColor))

        let hexFallback = SvgPaint.parse("url(#grad1) #0f0")
        @Assert(hexFallback.fallback == Some(SvgPaint.of(SvgColor.fromRgb(0, 255, 0))))
    }

    /** 外部引用与非法语法。 */
    @TestCase
    public func rejectsExternalAndBadSyntax(): Unit {
        let external = [
            "url(\"http://example.com/x.svg#g\")",
            "url(https://x/y.png)",
            "url(//evil/x.svg#a)",
            "url(file:///etc/passwd#a)",
            "url(javascript:alert(1))",
            "url(data:image/png;base64,AAAA)"
        ]
        for (text in external) {
            let current = text
            let error = expectSvgException({=> SvgPaint.parse(current)})
            @Assert(error.kind == SvgErrorKind.Security)
        }
        let malformed = ["", "   ", "url()", "url(#)", "url(#a", "url(#a) url(#b)", "url(#a) #zzz", "notacolor"]
        for (text in malformed) {
            let current = text
            let error = expectSvgException({=> SvgPaint.parse(current)})
            @Assert(error.kind == SvgErrorKind.InvalidValue)
        }
    }

    /** 工厂与序列化。 */
    @TestCase
    public func factoriesAndToString(): Unit {
        @Assert(SvgPaint.None.toString() == "none")
        @Assert(SvgPaint.CurrentColor.toString() == "currentColor")
        @Assert(SvgPaint.of(SvgColor.fromRgb(255, 0, 0)).toString() == "#ff0000")
        @Assert(SvgPaint.referencing("#g").toString() == "url(#g)")
        let withFallback = SvgPaint.referencing("#g", fallback: Some(SvgPaint.None))
        @Assert(withFallback.toString() == "url(#g) none")
    }

    /** parse(toString(x)) == x。 */
    @TestCase
    public func roundTrip(): Unit {
        let samples = [
            SvgPaint.None,
            SvgPaint.CurrentColor,
            SvgPaint.of(SvgColor.fromRgb(1, 2, 3)),
            SvgPaint.of(SvgColor.fromRgb(1, 2, 3, alpha: 0.5)),
            SvgPaint.referencing("#g"),
            SvgPaint.referencing("#g", fallback: Some(SvgPaint.None)),
            SvgPaint.referencing("#g", fallback: Some(SvgPaint.CurrentColor)),
            SvgPaint.referencing("#g", fallback: Some(SvgPaint.of(SvgColor.Black)))
        ]
        for (paint in samples) {
            @Assert(SvgPaint.parse(paint.toString()) == paint)
        }
    }

    /** 引用解析的中间结果结构。 */
    @TestCase
    public func serverReference(): Unit {
        let reference = SvgPaintServerRef("#grad1")
        @Assert(reference.id == "#grad1")
    }
}

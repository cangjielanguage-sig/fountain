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
public class SvgColor_test {
    /** 十六进制短写、长写与 8 位扩展。 */
    @TestCase
    public func hexForms(): Unit {
        @Assert(SvgColor.parse("#f00") == SvgColor.fromRgb(255, 0, 0))
        @Assert(SvgColor.parse("#FF0000") == SvgColor.fromRgb(255, 0, 0))
        @Assert(SvgColor.parse("#F00") == SvgColor.parse("#f00"))
        @Assert(SvgColor.parse("#00ff0088") == SvgColor.fromRgb(0, 255, 0, alpha: Float64(0x88) / 255.0))
        let alphaColor = SvgColor.parse("#ff000080")
        @Assert(alphaColor.red == 255 && alphaColor.green == 0 && alphaColor.blue == 0)
        @Assert(near(alphaColor.alpha, 128.0 / 255.0))
    }

    /** rgb 的逗号与空格两种语法。 */
    @TestCase
    public func rgbSyntax(): Unit {
        @Assert(SvgColor.parse("rgb(255, 0, 0)") == SvgColor.fromRgb(255, 0, 0))
        @Assert(SvgColor.parse("rgb(255 0 0)") == SvgColor.fromRgb(255, 0, 0))
        @Assert(SvgColor.parse("RGB(0,128,255)") == SvgColor.fromRgb(0, 128, 255))
        @Assert(SvgColor.parse("rgb( 1 , 2 , 3 )") == SvgColor.fromRgb(1, 2, 3))
    }

    /** 百分比分量与越界钳制。 */
    @TestCase
    public func percentComponentsAndClamping(): Unit {
        @Assert(SvgColor.parse("rgb(100%, 0%, 0%)") == SvgColor.fromRgb(255, 0, 0))
        @Assert(SvgColor.parse("rgb(50%, 0%, 0%)") == SvgColor.fromRgb(128, 0, 0))
        @Assert(SvgColor.parse("rgb(150%, -20%, 0%)") == SvgColor.fromRgb(255, 0, 0))
        @Assert(SvgColor.parse("rgb(300, -5, 0)") == SvgColor.fromRgb(255, 0, 0))
    }

    /** alpha 的数字、百分比与斜杠写法。 */
    @TestCase
    public func alphaForms(): Unit {
        @Assert(near(SvgColor.parse("rgba(255, 0, 0, 0.5)").alpha, 0.5))
        @Assert(near(SvgColor.parse("rgba(255, 0, 0, 50%)").alpha, 0.5))
        @Assert(near(SvgColor.parse("rgb(255 0 0 / 50%)").alpha, 0.5))
        @Assert(near(SvgColor.parse("rgb(255 0 0 / 0.25)").alpha, 0.25))
        @Assert(near(SvgColor.parse("rgba(0,0,0,2)").alpha, 1.0))
        @Assert(near(SvgColor.parse("rgba(0,0,0,-1)").alpha, 0.0))
    }

    /** hsl 六个色相区。 */
    @TestCase
    public func hslHueSectors(): Unit {
        @Assert(SvgColor.parse("hsl(0, 100%, 50%)") == SvgColor.fromRgb(255, 0, 0))
        @Assert(SvgColor.parse("hsl(60, 100%, 50%)") == SvgColor.fromRgb(255, 255, 0))
        @Assert(SvgColor.parse("hsl(120, 100%, 50%)") == SvgColor.fromRgb(0, 255, 0))
        @Assert(SvgColor.parse("hsl(180, 100%, 50%)") == SvgColor.fromRgb(0, 255, 255))
        @Assert(SvgColor.parse("hsl(240, 100%, 50%)") == SvgColor.fromRgb(0, 0, 255))
        @Assert(SvgColor.parse("hsl(300, 100%, 50%)") == SvgColor.fromRgb(255, 0, 255))
        @Assert(SvgColor.parse("hsl(120deg, 100%, 50%)") == SvgColor.fromRgb(0, 255, 0))
        @Assert(SvgColor.parse("hsl(120 100% 50%)") == SvgColor.fromRgb(0, 255, 0))
    }

    /** hsla 与无彩色（饱和度 0）。 */
    @TestCase
    public func hslaAndGray(): Unit {
        let color = SvgColor.parse("hsla(0, 100%, 50%, .5)")
        @Assert(color.red == 255 && color.green == 0 && color.blue == 0)
        @Assert(near(color.alpha, 0.5))
        @Assert(SvgColor.parse("hsl(0, 0%, 0%)") == SvgColor.fromRgb(0, 0, 0))
        @Assert(SvgColor.parse("hsl(0, 0%, 100%)") == SvgColor.fromRgb(255, 255, 255))
        @Assert(SvgColor.parse("hsl(0, 0%, 50%)") == SvgColor.fromRgb(128, 128, 128))
    }

    /** transparent 与命名色。 */
    @TestCase
    public func namedColors(): Unit {
        @Assert(SvgColor.parse("transparent") == SvgColor.Transparent)
        @Assert(SvgColor.Transparent.red == 0 && SvgColor.Transparent.green == 0 && SvgColor.Transparent.blue == 0)
        @Assert(near(SvgColor.Transparent.alpha, 0.0))
        @Assert(SvgColor.parse("red") == SvgColor.fromRgb(255, 0, 0))
        @Assert(SvgColor.parse("RED") == SvgColor.fromRgb(255, 0, 0))
        @Assert(SvgColor.parse("rebeccapurple") == SvgColor.fromRgb(102, 51, 153))
        @Assert(SvgColor.parse("salmon") == SvgColor.fromRgb(250, 128, 114))
        @Assert(SvgColor.parse("aliceblue") == SvgColor.fromRgb(240, 248, 255))
        @Assert(SvgColor.parse("darkslategray") == SvgColor.fromRgb(47, 79, 79))
        @Assert(SvgColor.parse("yellowgreen") == SvgColor.fromRgb(154, 205, 50))
        @Assert(SvgColor.Black == SvgColor.fromRgb(0, 0, 0))
        @Assert(SvgColor.White == SvgColor.fromRgb(255, 255, 255))
    }

    /** 非法输入：画笔关键字、未知色名、空串、分量个数错误。 */
    @TestCase
    public func invalidInputs(): Unit {
        let bad = [
            "none", "notacolor", "", "   ", "#ff", "#gggggg", "#12345",
            "rgb(1,2)", "rgb(1,2,3,4,5)", "hsl(1,2)", "hsl(1,2%,3%,4%,5%)",
            "rgb(1,2,3", "rgb 1 2 3"
        ]
        for (text in bad) {
            let current = text
            let error = expectSvgException({=> SvgColor.parse(current)})
            @Assert(error.kind == SvgErrorKind.InvalidValue)
            @Assert(SvgColor.tryParse(current).isNone())
        }
    }

    /** toString：不透明用 #rrggbb；alpha 可按字节精确表示时用 #rrggbbaa。 */
    @TestCase
    public func toStringForms(): Unit {
        @Assert(SvgColor.fromRgb(255, 0, 0).toString() == "#ff0000")
        @Assert(SvgColor.fromRgb(0, 128, 255).toString() == "#0080ff")
        @Assert(SvgColor.fromRgb(255, 0, 0, alpha: 0.5).toString() == "rgba(255,0,0,0.5)")
        @Assert(SvgColor.Transparent.toString() == "#00000000")
        @Assert(SvgColor.fromRgb(0, 255, 0, alpha: Float64(0x88) / 255.0).toString() == "#00ff0088")
    }

    /** #rrggbbaa 精确往返；6 位小数可表示的 alpha 不参与。 */
    @TestCase
    public func hexAlphaRoundTrip(): Unit {
        let samples = [
            SvgColor.parse("#ff000080"),
            SvgColor.fromRgb(0, 255, 0, alpha: Float64(0x88) / 255.0),
            SvgColor.parse("#00000000"),
            SvgColor.fromRgb(18, 52, 86, alpha: Float64(255) / 255.0)
        ]
        for (color in samples) {
            let text = color.toString()
            @Assert(text.startsWith("#"))
            @Assert(SvgColor.parse(text) == color)
        }
        @Assert(SvgColor.parse("#ff000080").toString() == "#ff000080")
    }

    /** 非有限 alpha 在序列化时按 InvalidValue 拒绝，不做字节转换。 */
    @TestCase
    public func nonFiniteAlphaRejected(): Unit {
        let nanError = expectSvgException({=> SvgColor(0, 0, 0, alpha: Float64.NaN)})
        @Assert(nanError.kind == SvgErrorKind.InvalidValue)
        let infError = expectSvgException({=> SvgColor(0, 0, 0, alpha: Float64.Inf)})
        @Assert(infError.kind == SvgErrorKind.InvalidValue)
    }

    /** 不能由字节精确表示的 alpha 仍走 rgba() 并往返。 */
    @TestCase
    public func decimalAlphaRoundTrip(): Unit {
        let samples = [
            SvgColor.fromRgb(0, 0, 0),
            SvgColor.fromRgb(255, 255, 255),
            SvgColor.fromRgb(18, 52, 86),
            SvgColor.fromRgb(1, 2, 3, alpha: 0.5),
            SvgColor.fromRgb(4, 5, 6, alpha: 0.25)
        ]
        for (color in samples) {
            @Assert(SvgColor.parse(color.toString()) == color)
        }
    }

    /** fromHsl 直接调用与 hsl 解析一致。 */
    @TestCase
    public func fromHslDirect(): Unit {
        @Assert(SvgColor.fromHsl(120.0, 1.0, 0.5) == SvgColor.fromRgb(0, 255, 0))
        @Assert(SvgColor.fromHsl(0.0, 1.0, 0.5, alpha: 0.5) == SvgColor.fromRgb(255, 0, 0, alpha: 0.5))
    }

    /** 全部命名色都能被解析，确保表没有明显缺口。 */
    @TestCase
    public func namedTableIsComplete(): Unit {
        let names = [
            "aliceblue", "antiquewhite", "aqua", "aquamarine", "azure", "beige", "bisque", "black",
            "blanchedalmond", "blue", "blueviolet", "brown", "burlywood", "cadetblue", "chartreuse",
            "chocolate", "coral", "cornflowerblue", "cornsilk", "crimson", "cyan", "darkblue", "darkcyan",
            "darkgoldenrod", "darkgray", "darkgreen", "darkgrey", "darkkhaki", "darkmagenta",
            "darkolivegreen", "darkorange", "darkorchid", "darkred", "darksalmon", "darkseagreen",
            "darkslateblue", "darkslategray", "darkslategrey", "darkturquoise", "darkviolet", "deeppink",
            "deepskyblue", "dimgray", "dimgrey", "dodgerblue", "firebrick", "floralwhite", "forestgreen",
            "fuchsia", "gainsboro", "ghostwhite", "gold", "goldenrod", "gray", "green", "greenyellow",
            "grey", "honeydew", "hotpink", "indianred", "indigo", "ivory", "khaki", "lavender",
            "lavenderblush", "lawngreen", "lemonchiffon", "lightblue", "lightcoral", "lightcyan",
            "lightgoldenrodyellow", "lightgray", "lightgreen", "lightgrey", "lightpink", "lightsalmon",
            "lightseagreen", "lightskyblue", "lightslategray", "lightslategrey", "lightsteelblue",
            "lightyellow", "lime", "limegreen", "linen", "magenta", "maroon", "mediumaquamarine",
            "mediumblue", "mediumorchid", "mediumpurple", "mediumseagreen", "mediumslateblue",
            "mediumspringgreen", "mediumturquoise", "mediumvioletred", "midnightblue", "mintcream",
            "mistyrose", "moccasin", "navajowhite", "navy", "oldlace", "olive", "olivedrab", "orange",
            "orangered", "orchid", "palegoldenrod", "palegreen", "paleturquoise", "palevioletred",
            "papayawhip", "peachpuff", "peru", "pink", "plum", "powderblue", "purple", "rebeccapurple",
            "red", "rosybrown", "royalblue", "saddlebrown", "salmon", "sandybrown", "seagreen",
            "seashell", "sienna", "silver", "skyblue", "slateblue", "slategray", "slategrey", "snow",
            "springgreen", "steelblue", "tan", "teal", "thistle", "tomato", "turquoise", "violet",
            "wheat", "white", "whitesmoke", "yellow", "yellowgreen"
        ]
        @Assert(names.size == 148)
        for (name in names) {
            @Assert(SvgColor.tryParse(name).isSome())
        }
    }
}

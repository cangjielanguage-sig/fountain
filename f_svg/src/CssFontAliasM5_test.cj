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

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

/** 每个码点固定 10 单位 advance 的测试字体。 */
internal class M5FixedAdvanceFont <: SvgFont {
    public func glyphPath(codePoint: Int64, fontSize: Float64): ?SvgPathData {
        None
    }

    public func advance(codePoint: Int64, fontSize: Float64): Float64 {
        10.0
    }

    public func ascent(fontSize: Float64): Float64 {
        8.0
    }

    public func descent(fontSize: Float64): Float64 {
        2.0
    }

    public func glyphBounds(codePoint: Int64, fontSize: Float64): ?SvgBounds {
        None
    }
}

internal func m5AliasRules(text: String): Array<CssFontFaceRule> {
    CssStyleSheet.parse(text).fontFaces
}

@Test
public class CssFontAliasM5_test {
    /** 别名命中：声明 family 指向注册表中唯一的 family。 */
    @TestCase
    public func aliasHitsRegisteredFamily(): Unit {
        let base = SvgFontRegistry()
        base.register("Brand", M5FixedAdvanceFont())
        let derived = SvgFontRegistry.derived(
            base,
            m5AliasRules("@font-face { font-family: Body; src: url(x.ttf) }")
        )
        let font = derived.resolve("Body", "normal", "normal")
        @Assert(font.isSome())
        match (font) {
            case Some(value) => @Assert(value.advance(65, 10.0) == 10.0)
            case None => ()
        }
    }

    /** 权重 / 风格未注册时回退目标的 normal / normal。 */
    @TestCase
    public func weightFallsBackToNormal(): Unit {
        let base = SvgFontRegistry()
        base.register("Brand", M5FixedAdvanceFont())
        let derived = SvgFontRegistry.derived(base, m5AliasRules("@font-face { font-family: Body }"))
        @Assert(derived.resolve("Body", "bold", "italic").isSome())
        @Assert(derived.resolve("Body", "700", "oblique").isSome())
    }

    /** 目标缺失：注册表为空时别名不生效，也不抛异常。 */
    @TestCase
    public func missingTarget(): Unit {
        let base = SvgFontRegistry()
        let derived = SvgFontRegistry.derived(base, m5AliasRules("@font-face { font-family: Ghost }"))
        @Assert(derived.resolve("Ghost", "normal", "normal").isNone())
        @Assert(derived.resolve("Other", "normal", "normal").isNone())
    }

    /** 派生注册表不写入输入注册表，重复派生结果稳定。 */
    @TestCase
    public func inputRegistryNotPolluted(): Unit {
        let base = SvgFontRegistry()
        base.register("Brand", M5FixedAdvanceFont())
        @Assert(base.resolve("Body", "normal", "normal").isNone())
        let aliases = m5AliasRules("@font-face { font-family: Body }")
        let first = SvgFontRegistry.derived(base, aliases)
        let second = SvgFontRegistry.derived(base, aliases)
        @Assert(first.resolve("Body", "normal", "normal").isSome())
        @Assert(second.resolve("Body", "normal", "normal").isSome())
        @Assert(base.resolve("Body", "normal", "normal").isNone())
    }

    /** 渲染器使用样式表别名：文本不再报告「未找到字体」，两次渲染一致。 */
    @TestCase
    public func rendererAppliesAlias(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"80\" height=\"30\"><style>" +
            "@font-face { font-family: Body }\n" +
            "text { font-family: Body; font-size: 10px }</style>" +
            "<text x=\"5\" y=\"20\">AB</text></svg>"
        )
        let base = SvgFontRegistry()
        base.register("Brand", M5FixedAdvanceFont())
        let renderer = SvgRenderer(
            options: SvgRenderOptions(samplesPerPixel: 1, fonts: base, width: 80, height: 30)
        )
        let first = renderer.render(document)
        var missing = false
        for (warning in renderer.warnings) {
            if (warning.contains("未找到字体")) {
                missing = true
            }
        }
        @Assert(!missing)
        let second = SvgRenderer(
            options: SvgRenderOptions(samplesPerPixel: 1, fonts: base, width: 80, height: 30)
        ).render(document)
        @Assert(first.pixels == second.pixels)
        @Assert(base.resolve("Body", "normal", "normal").isNone())
    }
}

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

/** 每个码点固定 advance 的测试字体；默认 10 单位。 */
internal class M5FixedAdvanceFont <: SvgFont {
    private let advancing: Float64

    init(advancing!: Float64 = 10.0) {
        this.advancing = advancing
    }

    public func glyphPath(codePoint: Int64, fontSize: Float64): ?SvgPathData {
        None
    }

    public func advance(codePoint: Int64, fontSize: Float64): Float64 {
        this.advancing
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
    /** `src: local(Brand)`：未注册的 family 使用已注册 Brand 的字体。 */
    @TestCase
    public func localSourceAliasesRegisteredFamily(): Unit {
        let base = SvgFontRegistry()
        base.register("Brand", M5FixedAdvanceFont(advancing: 42.0))
        let derived = SvgFontRegistry.derived(
            base,
            m5AliasRules("@font-face { font-family: Body; src: local(Brand) }")
        )
        @Assert(base.resolve("Body", "normal", "normal").isNone())
        match (derived.resolve("Body", "normal", "normal")) {
            case Some(value) => @Assert(value.advance(65, 10.0) == 42.0)
            case None => @Fail("Body 应通过 local(Brand) 命中 Brand")
        }
    }

    /** `src: local(Missing)`：目标未注册，不建别名也不回退其他 family。 */
    @TestCase
    public func localSourceWithoutRegisteredTarget(): Unit {
        let base = SvgFontRegistry()
        base.register("Brand", M5FixedAdvanceFont(advancing: 42.0))
        let warnings = ArrayList<String>()
        let sheet = CssStyleSheet.parse(
            "@font-face { font-family: Body; src: local(Missing) }",
            warnings
        )
        let derived = SvgFontRegistry.derived(base, sheet.fontFaces, warnings: warnings)
        @Assert(derived.resolve("Body", "normal", "normal").isNone())
        var sawMissing = false
        for (warning in warnings) {
            if (warning.contains("Missing")) {
                sawMissing = true
            }
        }
        @Assert(sawMissing)
    }

    /** `src: url(...)`：不加载文件，同名已注册时保留恒等别名并记 src warning。 */
    @TestCase
    public func urlSourceKeepsIdentityAlias(): Unit {
        let base = SvgFontRegistry()
        base.register("Body", M5FixedAdvanceFont(advancing: 7.0))
        let warnings = ArrayList<String>()
        let sheet = CssStyleSheet.parse(
            "@font-face { font-family: Body; src: url(x.ttf) }",
            warnings
        )
        let derived = SvgFontRegistry.derived(base, sheet.fontFaces, warnings: warnings)
        match (derived.resolve("Body", "normal", "normal")) {
            case Some(value) => @Assert(value.advance(65, 10.0) == 7.0)
            case None => @Fail("同名已注册时应保留恒等别名")
        }
        var sawSrc = false
        for (warning in warnings) {
            if (warning.contains("src")) {
                sawSrc = true
            }
        }
        @Assert(sawSrc)
    }

    /** 权重 / 风格未注册时回退目标的 normal / normal。 */
    @TestCase
    public func weightFallsBackToNormal(): Unit {
        let base = SvgFontRegistry()
        base.register("Brand", M5FixedAdvanceFont(advancing: 42.0))
        let derived = SvgFontRegistry.derived(
            base,
            m5AliasRules("@font-face { font-family: Body; src: local(Brand) }")
        )
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

    /** 默认注册表下目标缺失：不得映射到首个 family（Hershey），并记 warning。 */
    @TestCase
    public func missingTargetDoesNotUsePrimaryFamily(): Unit {
        let warnings = ArrayList<String>()
        let derived = SvgFontRegistry.derived(
            SvgFontRegistry.defaultRegistry(),
            m5AliasRules("@font-face { font-family: Missing }"),
            warnings: warnings
        )
        @Assert(derived.resolve("Missing", "normal", "normal").isNone())
        var sawMissing = false
        for (warning in warnings) {
            if (warning.contains("Missing")) {
                sawMissing = true
            }
        }
        @Assert(sawMissing)
    }

    /** 缺失别名时文本继续按 family 列表常规回退。 */
    @TestCase
    public func missingAliasFallsBackToNextFamily(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"80\" height=\"30\"><style>" +
            "@font-face { font-family: Missing }\n" +
            "text { font-family: Missing, sans-serif; font-size: 10px }</style>" +
            "<text x=\"5\" y=\"20\">AB</text></svg>"
        )
        let renderer = SvgRenderer()
        let bitmap = renderer.render(document)
        var painted = false
        for (index in 0..bitmap.pixels.size / 4) {
            if (bitmap.pixels[index * 4 + 3] > 0) {
                painted = true
                break
            }
        }
        @Assert(painted)
        var sawMissing = false
        for (warning in renderer.warnings) {
            if (warning.contains("Missing")) {
                sawMissing = true
            }
        }
        @Assert(sawMissing)
    }

    /** 派生注册表不写入输入注册表，重复派生结果稳定。 */
    @TestCase
    public func inputRegistryNotPolluted(): Unit {
        let base = SvgFontRegistry()
        base.register("Brand", M5FixedAdvanceFont(advancing: 42.0))
        let aliases = m5AliasRules("@font-face { font-family: Body; src: local(Brand) }")
        let first = SvgFontRegistry.derived(base, aliases)
        let second = SvgFontRegistry.derived(base, aliases)
        @Assert(first.resolve("Body", "normal", "normal").isSome())
        @Assert(second.resolve("Body", "normal", "normal").isSome())
        @Assert(base.resolve("Body", "normal", "normal").isNone())
        @Assert(base.resolve("Brand", "normal", "normal").isSome())
    }

    /** 渲染器使用样式表别名：文本不再报告「未找到字体」，两次渲染一致。 */
    @TestCase
    public func rendererAppliesAlias(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"80\" height=\"30\"><style>" +
            "@font-face { font-family: Body; src: local(Brand) }\n" +
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

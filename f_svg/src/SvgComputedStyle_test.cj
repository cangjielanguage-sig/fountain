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
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*

internal func styleOf(tree: SvgComputedStyleTree, element: SvgElement): SvgComputedStyle {
    match (tree.get(element)) {
        case Some(style) => style
        case None => throw SvgException("缺少计算样式")
    }
}

internal func computeTree(root: SvgElement): SvgComputedStyleTree {
    computeTree(root, "")
}

internal func computeTree(root: SvgElement, css: String): SvgComputedStyleTree {
    let resolver = SvgStyleResolver(sheet: CssStyleSheet.parse(css))
    resolver.compute(root)
}

internal func computedFill(root: SvgElement, element: SvgElement, css: String): String {
    let style = styleOf(computeTree(root, css), element)
    style.get("fill") ?? "<missing>"
}

@Test
public class SvgComputedStyle_test {
    /** 属性元数据表、初始值、规范化 getter 与来源。 */
    @TestCase
    public func metadataAndInitialValues(): Unit {
        let rect = SvgRect()
        let tree = computeTree(rect)
        let style = styleOf(tree, rect)
        @Assert(tree.size == 1)
        @Assert(style.has("fill"))
        @Assert(style.get("fill") == Some("#000000"))
        @Assert(style.get("stroke") == Some("none"))
        @Assert(style.get("fill-rule") == Some("nonzero"))
        @Assert(style.get("stroke-linecap") == Some("butt"))
        @Assert(style.get("stroke-linejoin") == Some("miter"))
        @Assert(style.get("stroke-miterlimit") == Some("4"))
        @Assert(style.get("stroke-dasharray") == Some("none"))
        @Assert(style.get("visibility") == Some("visible"))
        @Assert(style.get("display") == Some("inline"))
        @Assert(style.get("unknown-property").isNone())
        @Assert(!style.has("unknown-property"))
        @Assert(style.opacity() == 1.0)
        @Assert(style.color() == SvgColor.Black)
        @Assert(style.strokeWidth() == SvgLength(1.0))
        @Assert(style.fontFamily() == "sans-serif")
        @Assert(style.fontSize() == SvgLength(16.0, unit: SvgLengthUnit.Px))
        @Assert(style.fillRule() == SvgFillRule.Nonzero)
        @Assert(style.source == CssStyleSource.Default)
        @Assert(style.sourceOf("fill") == CssStyleSource.Default)

        rect.setAttr("fill", "RED")
        let presented = styleOf(computeTree(rect), rect)
        @Assert(presented.get("fill") == Some("#ff0000"))
        @Assert(presented.sourceOf("fill") == CssStyleSource.Presentation)
    }

    /** 六级级联交叉矩阵。 */
    @TestCase
    public func cascadeMatrix(): Unit {
        let presentation = SvgRect()
        presentation.setAttr("fill", "red")
        @Assert(computedFill(presentation, presentation, "") == "#ff0000")

        let sheetBeatsPresentation = SvgRect()
        sheetBeatsPresentation.setAttr("fill", "red")
        @Assert(computedFill(sheetBeatsPresentation, sheetBeatsPresentation, "rect { fill: green }") == "#008000")

        let inlineBeatsSheet = SvgRect()
        inlineBeatsSheet.style = "fill: blue"
        @Assert(computedFill(inlineBeatsSheet, inlineBeatsSheet, "rect { fill: green }") == "#0000ff")

        let importantBeatsInline = SvgRect()
        importantBeatsInline.style = "fill: blue"
        @Assert(
            computedFill(importantBeatsInline, importantBeatsInline, "rect { fill: green !important }") == "#008000"
        )

        let inlineImportant = SvgRect()
        inlineImportant.style = "fill: blue !important"
        @Assert(
            computedFill(inlineImportant, inlineImportant, "rect { fill: green !important }") == "#0000ff"
        )

        let sourceOrder = SvgRect()
        @Assert(computedFill(sourceOrder, sourceOrder, "rect { fill: red } rect { fill: blue }") == "#0000ff")

        let specificity = SvgRect()
        specificity.className = "x"
        @Assert(computedFill(specificity, specificity, ".x { fill: red } rect { fill: blue }") == "#ff0000")

        let sheetImportantBeatsPresentation = SvgRect()
        sheetImportantBeatsPresentation.setAttr("fill", "red")
        @Assert(
            computedFill(
                sheetImportantBeatsPresentation,
                sheetImportantBeatsPresentation,
                "rect { fill: green !important }"
            ) == "#008000"
        )
    }

    /** 可继承属性、不可继承属性与 inherit / initial / unset。 */
    @TestCase
    public func inheritanceAndKeywords(): Unit {
        let root = SvgRoot()
        let group = SvgContainer(SvgContainerKind.Group)
        group.style = "fill: red; opacity: 0.5; font-size: 20px"
        let rect = SvgRect()
        group.appendElement(rect)
        root.appendElement(group)
        let tree = computeTree(root)
        let groupStyle = styleOf(tree, group)
        let rectStyle = styleOf(tree, rect)
        @Assert(groupStyle.get("opacity") == Some("0.5"))
        @Assert(rectStyle.get("opacity") == Some("1"))
        @Assert(rectStyle.get("fill") == Some("#ff0000"))
        @Assert(rectStyle.fontSize() == SvgLength(20.0, unit: SvgLengthUnit.Px))

        let inheritRoot = SvgRoot()
        let inheritGroup = SvgContainer(SvgContainerKind.Group)
        inheritGroup.style = "fill: red"
        let inheritRect = SvgRect()
        inheritRect.style = "fill: inherit"
        inheritGroup.appendElement(inheritRect)
        inheritRoot.appendElement(inheritGroup)
        @Assert(styleOf(computeTree(inheritRoot), inheritRect).get("fill") == Some("#ff0000"))

        let initialRoot = SvgRoot()
        let initialGroup = SvgContainer(SvgContainerKind.Group)
        initialGroup.style = "fill: red"
        let initialRect = SvgRect()
        initialRect.style = "fill: initial"
        initialGroup.appendElement(initialRect)
        initialRoot.appendElement(initialGroup)
        @Assert(styleOf(computeTree(initialRoot), initialRect).get("fill") == Some("#000000"))

        let unsetRoot = SvgRoot()
        let unsetGroup = SvgContainer(SvgContainerKind.Group)
        unsetGroup.style = "fill: red; opacity: 0.25"
        let unsetRect = SvgRect()
        unsetRect.style = "fill: unset; opacity: unset"
        unsetGroup.appendElement(unsetRect)
        unsetRoot.appendElement(unsetGroup)
        let relativeRoot = SvgRoot()
        let relativeGroup = SvgContainer(SvgContainerKind.Group)
        relativeGroup.style = "font-size: 20px"
        let relativeRect = SvgRect()
        relativeRect.style = "font-size: 2em"
        relativeGroup.appendElement(relativeRect)
        relativeRoot.appendElement(relativeGroup)
        @Assert(
            styleOf(computeTree(relativeRoot), relativeRect).fontSize() ==
            SvgLength(40.0, unit: SvgLengthUnit.Px)
        )

        let unsetStyle = styleOf(computeTree(unsetRoot), unsetRect)
        @Assert(unsetStyle.get("fill") == Some("#ff0000"))
        @Assert(unsetStyle.get("opacity") == Some("1"))
    }

    /** currentColor 两级继承与元素自身 color 覆盖。 */
    @TestCase
    public func currentColorResolution(): Unit {
        let root = SvgRoot()
        let group = SvgContainer(SvgContainerKind.Group)
        group.setAttr("color", "red")
        let fromParentColor = SvgRect()
        fromParentColor.style = "fill: currentColor"
        group.appendElement(fromParentColor)
        root.appendElement(group)
        @Assert(styleOf(computeTree(root), fromParentColor).get("fill") == Some("#ff0000"))

        let ownColor = SvgRect()
        ownColor.style = "color: blue; fill: currentColor"
        @Assert(computedFill(ownColor, ownColor, "") == "#0000ff")

        let inheritedCurrent = SvgRoot()
        let parent = SvgContainer(SvgContainerKind.Group)
        parent.style = "color: red; fill: currentColor"
        let child = SvgRect()
        parent.appendElement(child)
        inheritedCurrent.appendElement(parent)
        @Assert(styleOf(computeTree(inheritedCurrent), child).get("fill") == Some("#ff0000"))

        let sheetColor = SvgRect()
        sheetColor.style = "fill: currentColor"
        @Assert(computedFill(sheetColor, sheetColor, "rect { color: #00ff00 }") == "#00ff00")
    }

    /** 非法值降级与安全边界。 */
    @TestCase
    public func invalidValuesDegrade(): Unit {
        let resolver = SvgStyleResolver(sheet: CssStyleSheet.parse(
            "rect { mystery: 1; fill: bogus; stroke-width: wide; opacity: nope }"
        ))
        let rect = SvgRect()
        let style = styleOf(resolver.compute(rect), rect)
        @Assert(!style.has("mystery"))
        @Assert(style.get("fill") == Some("#000000"))
        @Assert(style.strokeWidth() == SvgLength(1.0))
        @Assert(style.opacity() == 1.0)
        @Assert(resolver.warnings.size >= 3)

        let external = SvgStyleResolver(sheet: CssStyleSheet.parse("rect { fill: url(http://example.com/a.svg#p) }"))
        let externalRect = SvgRect()
        let externalStyle = styleOf(external.compute(externalRect), externalRect)
        @Assert(externalStyle.fill().kind == SvgPaintKind.None)
        @Assert(external.warnings.size == 1)

        let fragment = SvgStyleResolver(sheet: CssStyleSheet.parse("rect { fill: url(#grad) }"))
        let fragmentRect = SvgRect()
        let fragmentStyle = styleOf(fragment.compute(fragmentRect), fragmentRect)
        @Assert(fragmentStyle.fill().kind == SvgPaintKind.Reference)
        @Assert(fragmentStyle.fill().reference == Some("#grad"))
        @Assert(fragment.warnings.size == 0)

        let root = SvgRoot()
        let parent = SvgElement("g")
        parent.setAttr("fill", "red")
        parent.setAttr("opacity", "0.5")
        let child = SvgRect()
        parent.appendElement(child)
        root.appendElement(parent)
        let inherited = SvgStyleResolver(sheet: CssStyleSheet.parse(
            "rect { fill: bogus; opacity: nope }"
        ))
        let inheritedStyle = styleOf(inherited.compute(root), child)
        @Assert(inheritedStyle.get("fill") == Some("#ff0000"))
        @Assert(inheritedStyle.opacity() == 1.0)
        var located = false
        for (warning in inherited.warnings) {
            if (warning.contains("/svg[1]/g[1]/rect[1]") && warning.contains("fill")) {
                located = true
            }
        }
        @Assert(located)

        let metadataRoot = SvgRoot()
        let metadataParent = SvgElement("g")
        metadataParent.setAttr("stop-color", "red")
        metadataParent.setAttr("stop-opacity", "0.5")
        let metadataChild = SvgRect()
        metadataParent.appendElement(metadataChild)
        metadataRoot.appendElement(metadataParent)
        let metadata = styleOf(computeTree(metadataRoot), metadataChild)
        @Assert(metadata.get("stop-color") == Some("#000000"))
        @Assert(metadata.get("stop-opacity") == Some("1"))

        let referenced = SvgRect()
        referenced.style = "clip-path: url(#c); mask: url(#m)"
        let referencedStyle = styleOf(computeTree(referenced), referenced)
        @Assert(referencedStyle.get("clip-path") == Some("url(#c)"))
        @Assert(referencedStyle.get("mask") == Some("url(#m)"))

        let relative = SvgRect()
        relative.style = "font-size: 16px; stroke-width: 2em; letter-spacing: 1ex; " +
            "word-spacing: 1.5em; stroke-dashoffset: 0.5em"
        let relativeStyle = styleOf(computeTree(relative), relative)
        @Assert(near(relativeStyle.strokeWidth().value, 32.0))
        @Assert(near(relativeStyle.letterSpacing().value, 8.0))
        @Assert(near(relativeStyle.wordSpacing().value, 24.0))
        @Assert(near(relativeStyle.strokeDashOffset().value, 8.0))

        let fontRoot = SvgRoot()
        let fontParent = SvgElement("g")
        fontParent.style = "font-size: 20px"
        let fontChild = SvgRect()
        fontChild.style = "font-size: bogus"
        fontParent.appendElement(fontChild)
        fontRoot.appendElement(fontParent)
        let fontResolver = SvgStyleResolver()
        let fontStyle = styleOf(fontResolver.compute(fontRoot), fontChild)
        @Assert(fontStyle.fontSize() == SvgLength(20.0, unit: SvgLengthUnit.Px))
        var fontWarning = false
        for (warning in fontResolver.warnings) {
            if (warning.contains("/svg[1]/g[1]/rect[1]") && warning.contains("font-size")) {
                fontWarning = true
            }
        }
        @Assert(fontWarning)
    }

    /** `<style>` 收集、外部样式表合并顺序与计算不修改文档。 */
    @TestCase
    public func styleElementAndNoMutation(): Unit {
        let root = SvgRoot()
        let styleElement = SvgElement("style")
        styleElement.appendText("rect { fill: green }")
        let rect = SvgRect()
        root.appendElement(styleElement)
        root.appendElement(rect)
        let before = root.toString()
        let resolver = SvgStyleResolver(sheet: CssStyleSheet.parse("rect { fill: red }"))
        let tree = resolver.compute(root)
        @Assert(styleOf(tree, rect).get("fill") == Some("#008000"))
        @Assert(root.toString() == before)
        @Assert(rect.attributes.size == 0)

        let externalWins = SvgRoot()
        let styleElement2 = SvgElement("style")
        styleElement2.appendText("rect { fill: green }")
        let rect2 = SvgRect()
        externalWins.appendElement(styleElement2)
        externalWins.appendElement(rect2)
        let resolver2 = SvgStyleResolver(sheet: CssStyleSheet.parse("rect { fill: red !important }"))
        @Assert(styleOf(resolver2.compute(externalWins), rect2).get("fill") == Some("#ff0000"))
    }

    /** computeElement 以显式父样式继承，且不依赖文档树。 */
    @TestCase
    public func computeElementWithParent(): Unit {
        let parent = SvgContainer(SvgContainerKind.Group)
        parent.style = "fill: red; font-size: 24px"
        let child = SvgRect()
        child.style = "fill: currentColor"
        parent.appendElement(child)
        let resolver = SvgStyleResolver()
        let noParent: ?SvgComputedStyle = None
        let parentStyle = resolver.computeElement(parent, noParent)
        let childStyle = resolver.computeElement(child, Some(parentStyle))
        @Assert(childStyle.get("fill") == Some("#000000"))
        @Assert(childStyle.fontSize() == SvgLength(24.0, unit: SvgLengthUnit.Px))

        let withoutParent = resolver.computeElement(child, noParent)
        @Assert(withoutParent.fontSize() == SvgLength(16.0, unit: SvgLengthUnit.Px))
    }

    /** 1000 条简单类选择器 × 1000 元素的匹配基准（只记录，不门禁）。 */
    @TestCase
    public func thousandByThousandBenchmark(): Unit {
        let rules = StringBuilder()
        for (index in 0..1000) {
            rules.append(".c${index} { fill: #010203 }\n")
        }
        let root = SvgRoot()
        for (index in 0..1000) {
            let rect = SvgRect()
            rect.className = "c" + index.toString()
            root.appendElement(rect)
        }
        let resolver = SvgStyleResolver(sheet: CssStyleSheet.parse(rules.toString()))
        let start = MonoTime.now()
        let tree = resolver.compute(root)
        let elapsed = MonoTime.now() - start
        @Assert(tree.size == 1001)
        println("CSS 1000 类选择器 x 1000 元素（匹配 + 计算样式）耗时: ${elapsed.toNanoseconds() / 1000000} ms")
    }
}

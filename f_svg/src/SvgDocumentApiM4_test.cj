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
public class SvgViewM4_test {
    /** view 映射、字段读写与往返。 */
    @TestCase
    public func model(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\">" +
            "<view id=\"v\" viewBox=\"0 0 10 20\" preserveAspectRatio=\"xMinYMax slice\" " +
            "viewTarget=\"a b\"/></svg>"
        )
        let views = document.views()
        @Assert(views.size == 1)
        let view = views[0]
        @Assert(view.id == Some("v"))
        @Assert(view.viewBox.getOrThrow().width == 10.0)
        @Assert(view.viewBox.getOrThrow().height == 20.0)
        @Assert(view.preserveAspectRatio.slice)
        @Assert(view.viewTarget == Some("a b"))

        let reparsed = SvgParser.parse(document.toString())
        let again = reparsed.views()[0]
        @Assert(again.viewBox == view.viewBox)
        @Assert(again.preserveAspectRatio == view.preserveAspectRatio)
        @Assert(again.viewTarget == view.viewTarget)
    }

    /** 修改 view 字段后写回再解析，值保持不变。 */
    @TestCase
    public func mutableRoundTrip(): Unit {
        let document = svgDoc('<view id="v" viewBox="0 0 10 10"/>')
        let view = document.views()[0]
        view.viewBox = tryParseSvgViewBox("1 2 30 40")
        view.preserveAspectRatio = tryParseSvgPreserveAspectRatio("none").getOrThrow()
        view.viewTarget = Some("x y")
        let reparsed = SvgParser.parse(document.toString())
        let again = reparsed.views()[0]
        @Assert(again.viewBox == view.viewBox)
        @Assert(again.preserveAspectRatio == view.preserveAspectRatio)
        @Assert(again.viewTarget == Some("x y"))

        // setter 写入默认值时会显式写出属性，而不是删除属性。
        again.preserveAspectRatio = SvgPreserveAspectRatio.Default
        @Assert(again.attr("preserveAspectRatio").isSome())
        @Assert(SvgParser.parse(reparsed.toString()).views()[0].preserveAspectRatio ==
            SvgPreserveAspectRatio.Default)

        // viewBox = None 删除属性。
        again.viewBox = None
        @Assert(again.attr("viewBox").isNone())
    }

    /** views() 文档顺序与 view(id) 查找。 */
    @TestCase
    public func documentQueries(): Unit {
        let document = svgDoc(
            '<view id="a" viewBox="0 0 1 1"/><rect width="1" height="1"/>' +
            '<view id="b" viewBox="0 0 2 2"/>'
        )
        let views = document.views()
        @Assert(views.size == 2)
        @Assert(views[0].id == Some("a"))
        @Assert(views[1].id == Some("b"))
        @Assert(document.view("b").isSome())
        @Assert(document.view("b").getOrThrow().viewBox.getOrThrow().width == 2.0)
        @Assert(document.view("missing").isNone())
    }

    /** forView 的 meet / none / slice 与非法视口。 */
    @TestCase
    public func viewportForView(): Unit {
        let view = SvgView()
        view.viewBox = tryParseSvgViewBox("0 0 100 50").getOrThrow()
        let meet = SvgViewport.forView(view, 200.0, 200.0)
        let point = meet.apply(SvgPoint(0.0, 0.0))
        @Assert(near(point.x, 0.0))
        @Assert(near(point.y, 50.0))

        view.preserveAspectRatio = tryParseSvgPreserveAspectRatio("none").getOrThrow()
        let stretch = SvgViewport.forView(view, 200.0, 200.0)
        @Assert(near(stretch.a, 2.0))
        @Assert(near(stretch.d, 4.0))

        view.preserveAspectRatio = tryParseSvgPreserveAspectRatio("xMidYMid slice").getOrThrow()
        let slice = SvgViewport.forView(view, 100.0, 100.0)
        @Assert(near(slice.a, 2.0))
        let offset = slice.apply(SvgPoint(0.0, 0.0))
        @Assert(near(offset.x, -50.0))

        let noBox = SvgView()
        @Assert(SvgViewport.forView(noBox, 10.0, 10.0) == SvgMatrix.identity)
        let noBoxError = expectSvgException({=> SvgViewport.forView(noBox, 0.0, 10.0)})
        @Assert(noBoxError.kind == SvgErrorKind.InvalidValue)

        let error = expectSvgException({=> SvgViewport.forView(view, 0.0, 10.0)})
        @Assert(error.kind == SvgErrorKind.InvalidValue)
    }

    /** view 不参与默认渲染。 */
    @TestCase
    public func viewNotRendered(): Unit {
        let withView = svgDoc(
            '<view id="v" viewBox="0 0 10 10"/><rect width="5" height="5" fill="red"/>',
            width: 10,
            height: 10
        )
        let withoutView = svgDoc(
            '<rect width="5" height="5" fill="red"/>',
            width: 10,
            height: 10
        )
        let first = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1)).render(withView)
        let second = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1)).render(withoutView)
        @Assert(first.pixels == second.pixels)

        let view = withView.views()[0]
        let blank = SvgRenderer().render(view, width: 10, height: 10)
        @Assert(blank.width == 10 && blank.height == 10)
        for (index in 0..blank.pixels.size) {
            @Assert(blank.pixels[index] == 0)
        }
    }
}

@Test
public class SvgSwitchM4_test {
    /** 语言前缀匹配与默认语言。 */
    @TestCase
    public func languageMatching(): Unit {
        let document = svgDoc(
            '<switch><rect systemLanguage="fr" width="10" height="10" fill="red"/>' +
            '<rect systemLanguage="zh" width="10" height="10" fill="blue"/></switch>',
            width: 10,
            height: 10
        )
        let bitmap = SvgRenderer(
            options: SvgRenderOptions(languages: ["zh-CN"], samplesPerPixel: 1)
        ).render(document)
        @Assert(bitmap.pixel(5, 5).blue > 200 && bitmap.pixel(5, 5).red < 60)

        let defaulted = svgDoc(
            '<switch><rect systemLanguage="en-US" width="10" height="10" fill="red"/>' +
            '<rect systemLanguage="zh" width="10" height="10" fill="blue"/></switch>',
            width: 10,
            height: 10
        )
        let defaultBitmap = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1))
            .render(defaulted)
        @Assert(defaultBitmap.pixel(5, 5).red > 200)
    }

    /** 多语言优先级按子元素顺序，不按 languages 顺序。 */
    @TestCase
    public func multiLanguagePriority(): Unit {
        let document = svgDoc(
            '<switch><rect systemLanguage="zh" width="10" height="10" fill="blue"/>' +
            '<rect systemLanguage="en" width="10" height="10" fill="red"/></switch>',
            width: 10,
            height: 10
        )
        let bitmap = SvgRenderer(
            options: SvgRenderOptions(languages: ["en", "zh"], samplesPerPixel: 1)
        ).render(document)
        @Assert(bitmap.pixel(5, 5).blue > 200 && bitmap.pixel(5, 5).red < 60)
    }

    /** 空的 requiredFeatures / systemLanguage 视为无要求。 */
    @TestCase
    public func emptyConditions(): Unit {
        let emptyFeatures = svgDoc(
            '<switch><rect requiredFeatures="" width="10" height="10" fill="red"/></switch>',
            width: 10,
            height: 10
        )
        @Assert(SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1))
            .render(emptyFeatures).pixel(5, 5).red > 200)

        let spacedFeatures = svgDoc(
            '<switch><rect requiredFeatures="   " width="10" height="10" fill="red"/></switch>',
            width: 10,
            height: 10
        )
        @Assert(SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1))
            .render(spacedFeatures).pixel(5, 5).red > 200)

        let emptyLanguage = svgDoc(
            '<switch><rect systemLanguage="" width="10" height="10" fill="red"/></switch>',
            width: 10,
            height: 10
        )
        @Assert(SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1))
            .render(emptyLanguage).pixel(5, 5).red > 200)
    }

    /** requiredFeatures / requiredExtensions / 全部不满足 / display 交互。 */
    @TestCase
    public func conditions(): Unit {
        let features = svgDoc(
            '<switch><rect requiredFeatures="http://www.w3.org/TR/SVG11/feature#Shape" ' +
            'width="10" height="10" fill="red"/></switch>',
            width: 10,
            height: 10
        )
        @Assert(SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1))
            .render(features).pixel(5, 5).red > 200)

        let unknownFeature = svgDoc(
            '<switch><rect requiredFeatures="http://example.com/feature#Unknown" ' +
            'width="10" height="10" fill="red"/></switch>',
            width: 10,
            height: 10
        )
        @Assert(SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1))
            .render(unknownFeature).pixel(5, 5).alpha == 0.0)

        let extension = svgDoc(
            '<switch><rect requiredExtensions="http://example.com/ext" ' +
            'width="10" height="10" fill="red"/>' +
            '<rect width="10" height="10" fill="blue"/></switch>',
            width: 10,
            height: 10
        )
        let extensionBitmap = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1))
            .render(extension)
        @Assert(extensionBitmap.pixel(5, 5).blue > 200)

        let unsatisfied = svgDoc(
            '<switch><rect systemLanguage="fr" width="10" height="10" fill="red"/></switch>',
            width: 10,
            height: 10
        )
        @Assert(SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1))
            .render(unsatisfied).pixel(5, 5).alpha == 0.0)

        let displayNone = svgDoc(
            '<switch><rect systemLanguage="en" display="none" width="10" height="10" ' +
            'fill="red"/><rect systemLanguage="en" width="10" height="10" fill="blue"/></switch>',
            width: 10,
            height: 10
        )
        let displayBitmap = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1))
            .render(displayNone)
        @Assert(displayBitmap.pixel(5, 5).blue > 200 && displayBitmap.pixel(5, 5).red < 60)
    }
}

@Test
public class SvgAnchorM4_test {
    /** 嵌套顺序、target 默认与外部 href 移除。 */
    @TestCase
    public func anchors(): Unit {
        let document = svgDoc(
            '<a href="#x"><rect width="2" height="2"/>' +
            '<a href="#y" target="_blank"><rect width="2" height="2"/></a></a>' +
            '<a href="#z"><rect width="2" height="2"/></a>'
        )
        let anchors = document.anchors()
        @Assert(anchors.size == 3)
        @Assert(anchors[0].href == Some("#x"))
        @Assert(anchors[0].target == "")
        @Assert(anchors[1].href == Some("#y"))
        @Assert(anchors[1].target == "_blank")
        @Assert(anchors[2].href == Some("#z"))

        let external = svgDoc('<a href="https://example.com"><rect width="2" height="2"/></a>')
        let externalAnchors = external.anchors()
        @Assert(externalAnchors.size == 1)
        @Assert(externalAnchors[0].href.isNone())
        var warned = false
        for (warning in external.warnings) {
            if (warning.contains("外部引用")) {
                warned = true
            }
        }
        @Assert(warned)
    }

    /** 无 href 的 a 同样返回，href 为 None。 */
    @TestCase
    public func anchorsWithoutHref(): Unit {
        let document = svgDoc(
            '<a><rect width="2" height="2"/></a><a href="#z"><rect width="2" height="2"/></a>'
        )
        let anchors = document.anchors()
        @Assert(anchors.size == 2)
        @Assert(anchors[0].href.isNone())
        @Assert(anchors[0].target == "")
        @Assert(anchors[1].href == Some("#z"))
    }

    /** a 容器本身不改变渲染结果。 */
    @TestCase
    public func anchorRendersLikeContainer(): Unit {
        let withAnchor = svgDoc(
            '<a href="#x"><rect width="10" height="10" fill="red"/></a>',
            width: 10,
            height: 10
        )
        let withoutAnchor = svgDoc(
            '<rect width="10" height="10" fill="red"/>',
            width: 10,
            height: 10
        )
        let first = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1)).render(withAnchor)
        let second = SvgRenderer(options: SvgRenderOptions(samplesPerPixel: 1)).render(withoutAnchor)
        @Assert(first.pixels == second.pixels)
    }
}

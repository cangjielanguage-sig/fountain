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

@Test
public class SvgInitialViewM6_test {
    private let documentText = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20\" height=\"20\" " +
        "viewBox=\"0 0 20 20\">" +
        "<view id=\"v\" viewBox=\"0 0 10 10\"/>" +
        "<view id=\"novb\" viewTarget=\"r\"/>" +
        "<rect id=\"r\" x=\"0\" y=\"0\" width=\"10\" height=\"10\" fill=\"red\"/>" +
        "</svg>"

    /** `#id` 与 `id` 都命中 view；输出尺寸不变。 */
    @TestCase
    public func viewOverridesViewport(): Unit {
        let document = SvgParser.parse(this.documentText)
        let plain = SvgRenderer(options: SvgRenderOptions(width: 20, height: 20)).render(document)
        @Assert(plain.width == 20 && plain.height == 20)
        @Assert(plain.pixel(15, 15).alpha == 0.0)

        for (initial in ["#v", "v"]) {
            let bitmap = SvgRenderer(
                options: SvgRenderOptions(width: 20, height: 20, initialView: initial)
            ).render(document)
            @Assert(bitmap.width == 20 && bitmap.height == 20)
            @Assert(bitmap.pixel(15, 15).toString() == "#ff0000")
        }
    }

    /** 未命中 view / view 无 viewBox 都 warning 并回退根视口。 */
    @TestCase
    public func missingOrEmptyViewFallsBack(): Unit {
        let document = SvgParser.parse(this.documentText)
        for (initial in ["#missing", "novb"]) {
            let renderer = SvgRenderer(
                options: SvgRenderOptions(width: 20, height: 20, initialView: initial)
            )
            let bitmap = renderer.render(document)
            @Assert(bitmap.pixel(15, 15).alpha == 0.0)
            @Assert(bitmap.pixel(5, 5).toString() == "#ff0000")
            var warned = false
            for (warning in renderer.warnings) {
                if (warning.contains("initialView") || warning.contains("view")) {
                    warned = true
                }
            }
            @Assert(warned)
        }
    }

    /** `preserveAspectRatio` 参与视口映射。 */
    @TestCase
    public func preserveAspectRatioMapping(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20\" height=\"10\">" +
            "<view id=\"v\" viewBox=\"0 0 10 10\" preserveAspectRatio=\"xMidYMid meet\"/>" +
            "<rect x=\"0\" y=\"0\" width=\"10\" height=\"10\" fill=\"red\"/></svg>"
        )
        let bitmap = SvgRenderer(
            options: SvgRenderOptions(width: 20, height: 10, initialView: "#v")
        ).render(document)
        @Assert(bitmap.pixel(2, 5).alpha == 0.0)
        @Assert(bitmap.pixel(7, 5).toString() == "#ff0000")
        @Assert(bitmap.pixel(12, 5).toString() == "#ff0000")
    }

    /** viewTarget 不参与渲染。 */
    @TestCase
    public func viewTargetIgnored(): Unit {
        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20\" height=\"20\">" +
            "<view id=\"v\" viewBox=\"0 0 10 10\" viewTarget=\"other\"/>" +
            "<rect x=\"0\" y=\"0\" width=\"10\" height=\"10\" fill=\"red\"/></svg>"
        )
        let bitmap = SvgRenderer(
            options: SvgRenderOptions(width: 20, height: 20, initialView: "#v")
        ).render(document)
        @Assert(bitmap.pixel(15, 15).toString() == "#ff0000")
    }
}

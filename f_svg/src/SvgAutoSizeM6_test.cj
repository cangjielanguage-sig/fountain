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
import std.math.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
public class SvgAutoSizeM6_test {
    private func sizeOf(svg: String, warnings: ArrayList<String>): SvgAutoSizeSize {
        let document = SvgParser.parse(svg)
        let styles = SvgStyleResolver().compute(document.root)
        SvgAutoSize.rootSize(document.root, styles, 300.0, 150.0, warnings: Some(warnings))
    }

    /** 单轴 auto 按 viewBox 比例从另一轴推导，而非内容包围盒。 */
    @TestCase
    public func singleAxisUsesViewBoxRatio(): Unit {
        let warnings = ArrayList<String>()
        let size = sizeOf(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"auto\" height=\"100\" " +
            "viewBox=\"0 0 200 100\"><rect x=\"0\" y=\"0\" width=\"50\" height=\"20\"/></svg>",
            warnings
        )
        @Assert(abs(size.width - 200.0) < 1e-9)
        @Assert(abs(size.height - 100.0) < 1e-9)
        @Assert(warnings.size == 0)

        let heightWarnings = ArrayList<String>()
        let other = sizeOf(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"200\" height=\"auto\" " +
            "viewBox=\"0 0 200 100\"><rect x=\"0\" y=\"0\" width=\"50\" height=\"20\"/></svg>",
            heightWarnings
        )
        @Assert(abs(other.width - 200.0) < 1e-9)
        @Assert(abs(other.height - 100.0) < 1e-9)
    }

    /** 双轴 auto + 内容包围盒。 */
    @TestCase
    public func bothAxesUseContent(): Unit {
        let warnings = ArrayList<String>()
        let size = sizeOf(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"auto\" height=\"auto\">" +
            "<rect x=\"0\" y=\"0\" width=\"40\" height=\"20\"/></svg>",
            warnings
        )
        @Assert(abs(size.width - 40.0) < 1e-9)
        @Assert(abs(size.height - 20.0) < 1e-9)
        @Assert(warnings.size == 0)
    }

    /** 无法确定时回退缺省尺寸并 warning。 */
    @TestCase
    public func unknownSizeWarns(): Unit {
        let warnings = ArrayList<String>()
        let size = sizeOf(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"auto\" height=\"auto\"></svg>",
            warnings
        )
        @Assert(abs(size.width - 300.0) < 1e-9)
        @Assert(abs(size.height - 150.0) < 1e-9)
        var warned = false
        for (warning in warnings) {
            if (warning.contains("auto")) {
                warned = true
            }
        }
        @Assert(warned)
    }

    /** 嵌套 auto 取父视口 100%。 */
    @TestCase
    public func nestedAutoUsesParentViewport(): Unit {
        let parent = SvgRoot()
        let child = SvgRoot()
        child.setAttr("width", "auto")
        child.setAttr("height", "auto")
        parent.appendElement(child)
        let viewport = SvgViewport.nestedViewport(child, 300.0, 150.0)
        @Assert(abs(viewport.width - 300.0) < 1e-9)
        @Assert(abs(viewport.height - 150.0) < 1e-9)
    }

    /** 未声明 auto 不产生新 warning。 */
    @TestCase
    public func explicitSizeKeepsNoWarning(): Unit {
        let warnings = ArrayList<String>()
        let size = sizeOf(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"40\" height=\"20\"></svg>",
            warnings
        )
        @Assert(abs(size.width - 40.0) < 1e-9)
        @Assert(abs(size.height - 20.0) < 1e-9)
        @Assert(warnings.size == 0)
    }
}

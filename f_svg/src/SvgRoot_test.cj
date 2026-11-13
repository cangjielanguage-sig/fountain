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
public class SvgRoot_test {
    /** 缺省时所有几何属性为 None，不补默认值。 */
    @TestCase
    public func defaults(): Unit {
        let root = SvgRoot()
        @Assert(root.tag == "svg")
        @Assert(root.namespace == SvgNamespaces.SVG)
        @Assert(root.width.isNone())
        @Assert(root.height.isNone())
        @Assert(root.x.isNone())
        @Assert(root.y.isNone())
        @Assert(root.viewBox.isNone())
        @Assert(root.preserveAspectRatio.isNone())
        @Assert(root.attributes.size == 0)
    }

    /** 构造参数写入 width / height。 */
    @TestCase
    public func constructorArguments(): Unit {
        let root = SvgRoot(width: SvgLength(200.0, unit: SvgLengthUnit.Px), height: SvgLength(100.0))
        @Assert(root.width == Some(SvgLength(200.0, unit: SvgLengthUnit.Px)))
        @Assert(root.height == Some(SvgLength(100.0)))
        @Assert(root.attr("width") == Some("200px"))
        @Assert(root.attr("height") == Some("100"))
    }

    /** 长度属性的读写与删除。 */
    @TestCase
    public func lengthProperties(): Unit {
        let root = SvgRoot()
        root.x = SvgLength(1.0)
        root.y = SvgLength(2.5, unit: SvgLengthUnit.Percent)
        root.width = SvgLength(300.0, unit: SvgLengthUnit.Px)
        root.height = SvgLength(50.0, unit: SvgLengthUnit.Percent)
        @Assert(root.x == Some(SvgLength(1.0)))
        @Assert(root.y == Some(SvgLength(2.5, unit: SvgLengthUnit.Percent)))
        @Assert(root.width == Some(SvgLength(300.0, unit: SvgLengthUnit.Px)))
        @Assert(root.height == Some(SvgLength(50.0, unit: SvgLengthUnit.Percent)))
        @Assert(root.attr("x") == Some("1"))
        @Assert(root.attr("y") == Some("2.5%"))

        root.x = None
        @Assert(root.x.isNone())
        @Assert(root.attr("x").isNone())

        root.setAttr("width", "bogus")
        @Assert(root.width.isNone())
        root.setAttr("height", "1e")
        @Assert(root.height.isNone())
    }

    /** viewBox 读写。 */
    @TestCase
    public func viewBoxProperty(): Unit {
        let root = SvgRoot()
        root.viewBox = SvgViewBox(0.0, 0.0, 200.0, 100.0)
        @Assert(root.attr("viewBox") == Some("0 0 200 100"))
        @Assert(root.viewBox == Some(SvgViewBox(0.0, 0.0, 200.0, 100.0)))
        root.setAttr("viewBox", "0 0 0 100")
        @Assert(root.viewBox.isNone())
        root.viewBox = None
        @Assert(root.viewBox.isNone())
    }

    /** preserveAspectRatio 读写。 */
    @TestCase
    public func preserveAspectRatioProperty(): Unit {
        let root = SvgRoot()
        root.preserveAspectRatio = SvgPreserveAspectRatio(SvgAspectAlign.XMinYMax, slice: true)
        @Assert(root.attr("preserveAspectRatio") == Some("xMinYMax slice"))
        @Assert(root.preserveAspectRatio == Some(SvgPreserveAspectRatio(SvgAspectAlign.XMinYMax, slice: true)))
        root.setAttr("preserveAspectRatio", "bogus")
        @Assert(root.preserveAspectRatio.isNone())
        root.preserveAspectRatio = None
        @Assert(root.preserveAspectRatio.isNone())
    }

    /** 根元素可容纳子节点。 */
    @TestCase
    public func children(): Unit {
        let root = SvgRoot()
        let group = SvgElement("g")
        root.appendElement(group)
        @Assert(root.children.size == 1)
        @Assert(group.parent.getOrThrow() == root)
        @Assert(group.elementPath() == "/svg[1]/g[1]")
    }
}

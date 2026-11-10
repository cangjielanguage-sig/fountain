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
public class SvgFilter_test {
    /** filter 映射为 SvgFilter，primitives 按文档顺序。 */
    @TestCase
    public func typeAndPrimitiveOrder(): Unit {
        let document = SvgParser.parse(
            "<svg><defs><filter id=\"f\">" +
            "<feGaussianBlur stdDeviation=\"2\"/><feOffset dx=\"1\" dy=\"2\"/>" +
            "</filter></defs></svg>"
        )
        let element = document.root.child("defs").getOrThrow().child("filter").getOrThrow()
        @Assert(element is SvgFilter)
        let filter = (element as SvgFilter).getOrThrow()
        @Assert(filter.primitives.size == 2)
        @Assert(filter.primitives[0] is SvgFeGaussianBlur)
        @Assert(filter.primitives[1] is SvgFeOffset)
    }

    /** 区域属性缺省为 None，单位缺省为对象包围盒 / 用户坐标。 */
    @TestCase
    public func regionDefaults(): Unit {
        let filter = SvgFilter()
        @Assert(filter.tag == "filter")
        @Assert(filter.x.isNone())
        @Assert(filter.y.isNone())
        @Assert(filter.width.isNone())
        @Assert(filter.height.isNone())
        @Assert(filter.filterUnits == SvgCoordinateUnits.ObjectBoundingBox)
        @Assert(filter.primitiveUnits == SvgCoordinateUnits.UserSpaceOnUse)

        filter.x = SvgLength(1.0)
        filter.y = SvgLength(2.0)
        filter.width = SvgLength(3.0)
        filter.height = SvgLength(4.0)
        filter.filterUnits = SvgCoordinateUnits.UserSpaceOnUse
        filter.primitiveUnits = SvgCoordinateUnits.ObjectBoundingBox
        @Assert(filter.x == Some(SvgLength(1.0)))
        @Assert(filter.width == Some(SvgLength(3.0)))
        @Assert(filter.filterUnits == SvgCoordinateUnits.UserSpaceOnUse)
        @Assert(filter.primitiveUnits == SvgCoordinateUnits.ObjectBoundingBox)
    }

    /** 八个原语与 feMergeNode 的类型化属性。 */
    @TestCase
    public func primitiveProperties(): Unit {
        let document = SvgParser.parse(
            "<svg><filter id=\"all\">" +
            "<feGaussianBlur stdDeviation=\"2 3\"/>" +
            "<feOffset dx=\"4\" dy=\"5\"/>" +
            "<feFlood flood-color=\"#00FF00\" flood-opacity=\"0.5\"/>" +
            "<feBlend in2=\"a\" mode=\"multiply\"/>" +
            "<feComposite in2=\"b\" operator=\"arithmetic\" k1=\"0.1\" k2=\"0.2\" k3=\"0.3\" k4=\"0.4\"/>" +
            "<feMerge><feMergeNode in=\"a\"/><feMergeNode in=\"b\"/></feMerge>" +
            "<feColorMatrix type=\"saturate\" values=\"0.5\"/>" +
            "<feTile/>" +
            "</filter></svg>"
        )
        let filter = (document.root.child("filter").getOrThrow() as SvgFilter).getOrThrow()
        @Assert(filter.primitives.size == 8)

        let blur = (filter.primitives[0] as SvgFeGaussianBlur).getOrThrow()
        @Assert(blur.stdDeviation.values == [2.0, 3.0])
        @Assert(blur.inSource.isNone())
        @Assert(blur.result.isNone())

        let offset = (filter.primitives[1] as SvgFeOffset).getOrThrow()
        @Assert(offset.dx == SvgLength(4.0))
        @Assert(offset.dy == SvgLength(5.0))

        let flood = (filter.primitives[2] as SvgFeFlood).getOrThrow()
        @Assert(flood.floodColor == SvgPaint.of(SvgColor.parse("#00FF00")))
        @Assert(flood.floodOpacity == 0.5)

        let blend = (filter.primitives[3] as SvgFeBlend).getOrThrow()
        @Assert(blend.in2 == Some("a"))
        @Assert(blend.mode == SvgBlendMode.Multiply)

        let composite = (filter.primitives[4] as SvgFeComposite).getOrThrow()
        @Assert(composite.in2 == Some("b"))
        @Assert(composite.operatorKind == SvgCompositeOperator.Arithmetic)
        @Assert(composite.k1 == 0.1)
        @Assert(composite.k2 == 0.2)
        @Assert(composite.k3 == 0.3)
        @Assert(composite.k4 == 0.4)

        let merge = (filter.primitives[5] as SvgFeMerge).getOrThrow()
        @Assert(merge.inputs.size == 2)
        @Assert(merge.inputs[0] == "a")
        @Assert(merge.inputs[1] == "b")
        @Assert(merge.children.size == 2)
        match (merge.children[0]) {
            case ElementNode(node) => @Assert(node is SvgFeMergeNode)
            case _ => throw Exception("feMerge 首个子节点应为 feMergeNode")
        }

        let matrix = (filter.primitives[6] as SvgFeColorMatrix).getOrThrow()
        @Assert(matrix.matrixType == SvgColorMatrixType.Saturate)
        @Assert(matrix.values == [0.5])

        let tile = (filter.primitives[7] as SvgFeTile).getOrThrow()
        @Assert(tile.inSource.isNone())
    }

    /** 原语属性的缺省值。 */
    @TestCase
    public func primitiveDefaults(): Unit {
        let blur = SvgFeGaussianBlur()
        @Assert(blur.stdDeviation.values.size == 0)

        let offset = SvgFeOffset()
        @Assert(offset.dx == SvgLength(0.0))
        @Assert(offset.dy == SvgLength(0.0))

        let flood = SvgFeFlood()
        @Assert(flood.floodColor == SvgPaint.of(SvgColor.Black))
        @Assert(flood.floodOpacity == 1.0)

        let blend = SvgFeBlend()
        @Assert(blend.mode == SvgBlendMode.Normal)
        @Assert(blend.in2.isNone())

        let composite = SvgFeComposite()
        @Assert(composite.operatorKind == SvgCompositeOperator.Over)
        @Assert(composite.k1 == 0.0)
        @Assert(composite.in2.isNone())

        let matrix = SvgFeColorMatrix()
        @Assert(matrix.matrixType == SvgColorMatrixType.Matrix)
        @Assert(matrix.values.size == 0)

        let tile = SvgFeTile()
        @Assert(tile.inSource.isNone())
    }

    /** 非 fe* 子元素不进 primitives，并记 warning。 */
    @TestCase
    public func nonPrimitiveChildWarns(): Unit {
        let document = SvgParser.parse(
            "<svg><filter id=\"f\"><rect width=\"1\" height=\"1\"/>" +
            "<feGaussianBlur stdDeviation=\"1\"/></filter></svg>"
        )
        let filter = (document.root.child("filter").getOrThrow() as SvgFilter).getOrThrow()
        @Assert(filter.primitives.size == 1)
        @Assert(filter.children.size == 2)
        var found = false
        for (warning in document.warnings) {
            if (warning.contains("filter") && warning.contains("fe")) {
                found = true
            }
        }
        @Assert(found)
    }
}

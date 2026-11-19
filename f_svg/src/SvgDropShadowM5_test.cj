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

internal func m5FirstPrimitive(svg: String): SvgFilterPrimitive {
    let document = SvgParser.parse(svg)
    let filter = document.elementsByTag("filter")[0]
    match (filter) {
        case value: SvgFilter =>
            if (value.primitives.size == 0) {
                @Fail("滤镜没有原语")
            }
            value.primitives[0]
        case _ => @Fail("不是 SvgFilter")
    }
}

@Test
public class SvgDropShadowM5_test {
    /** 类型化解析：字段与源值一致。 */
    @TestCase
    public func typedParsing(): Unit {
        let primitive = m5FirstPrimitive(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><filter id=\"f\">" +
            "<feDropShadow dx=\"4\" dy=\"5\" stdDeviation=\"3 1\" flood-color=\"blue\" " +
            "flood-opacity=\"0.5\"/></filter></svg>"
        )
        match (primitive) {
            case shadow: SvgFeDropShadow =>
                @Assert(shadow.dx.value == 4.0)
                @Assert(shadow.dy.value == 5.0)
                @Assert(shadow.stdDeviation.values == [3.0, 1.0])
                @Assert(shadow.floodColor.toString() == "#0000ff")
                @Assert(shadow.floodOpacity == 0.5)
            case _ => @Fail("应解析为 SvgFeDropShadow")
        }
    }

    /** 缺省值：dx=2、dy=2、stdDeviation=2、黑色、不透明。 */
    @TestCase
    public func defaults(): Unit {
        let primitive = m5FirstPrimitive(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><filter id=\"f\">" +
            "<feDropShadow/></filter></svg>"
        )
        match (primitive) {
            case shadow: SvgFeDropShadow =>
                @Assert(shadow.dx.value == 2.0)
                @Assert(shadow.dy.value == 2.0)
                @Assert(shadow.stdDeviation.values == [2.0])
                @Assert(shadow.floodColor.toString() == "#000000")
                @Assert(shadow.floodOpacity == 1.0)
            case _ => @Fail("应解析为 SvgFeDropShadow")
        }
    }

    /** 单值 stdDeviation 同时作用于 x / y。 */
    @TestCase
    public func singleDeviation(): Unit {
        let primitive = m5FirstPrimitive(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><filter id=\"f\">" +
            "<feDropShadow stdDeviation=\"1.5\"/></filter></svg>"
        )
        match (primitive) {
            case shadow: SvgFeDropShadow =>
                @Assert(shadow.stdDeviation.values == [1.5])
            case _ => @Fail("应解析为 SvgFeDropShadow")
        }
    }

    /** 写入后往返一致。 */
    @TestCase
    public func writeRoundTrip(): Unit {
        let shadow = SvgFeDropShadow()
        shadow.dx = SvgLength(6.0)
        shadow.dy = SvgLength(-3.0)
        shadow.stdDeviation = SvgNumberList([2.0, 4.0])
        shadow.floodColor = SvgPaint.of(SvgColor.fromRgb(255, 0, 0))
        shadow.floodOpacity = 0.25
        let serialized = shadow.toString()
        let reparsed = m5FirstPrimitive(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><filter id=\"f\">" + serialized +
            "</filter></svg>"
        )
        match (reparsed) {
            case value: SvgFeDropShadow =>
                @Assert(value.dx.value == 6.0)
                @Assert(value.dy.value == -3.0)
                @Assert(value.stdDeviation.values == [2.0, 4.0])
                @Assert(value.floodColor.toString() == "#ff0000")
                @Assert(value.floodOpacity == 0.25)
            case _ => @Fail("往返后应仍是 SvgFeDropShadow")
        }
    }

    /** 标签注册：create 与 isKnown 均识别。 */
    @TestCase
    public func tagRegistration(): Unit {
        @Assert(SvgTag.isKnown("feDropShadow"))
        match (SvgTag.create("feDropShadow")) {
            case Some(element) => @Assert(element is SvgFeDropShadow)
            case None => @Fail("SvgTag.create 应创建 feDropShadow")
        }
    }
}

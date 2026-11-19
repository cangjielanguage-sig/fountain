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
public class SvgClipPropertyM4_test {
    /** auto / none 不产生裁剪矩形。 */
    @TestCase
    public func autoAndNone(): Unit {
        @Assert(SvgClipProperty.parse("auto").isNone())
        @Assert(SvgClipProperty.parse("none").isNone())
        @Assert(SvgClipProperty.normalize("auto") == Some("auto"))
        @Assert(SvgClipProperty.normalize("none") == Some("none"))
    }

    /** 四边长度与逗号 / 空白分隔。 */
    @TestCase
    public func fourSides(): Unit {
        let comma = SvgClipProperty.parse("rect(1px, 2px, 3px, 4px)")
        @Assert(comma.isSome())
        @Assert(comma.getOrThrow().top == Some(1.0))
        @Assert(comma.getOrThrow().right == Some(2.0))
        @Assert(comma.getOrThrow().bottom == Some(3.0))
        @Assert(comma.getOrThrow().left == Some(4.0))

        let spaces = SvgClipProperty.parse("rect(0 10 20 5)")
        @Assert(spaces.isSome())
        @Assert(spaces.getOrThrow().top == Some(0.0))
        @Assert(spaces.getOrThrow().right == Some(10.0))
        @Assert(spaces.getOrThrow().bottom == Some(20.0))
        @Assert(spaces.getOrThrow().left == Some(5.0))

        @Assert(SvgClipProperty.normalize("rect(0px, 10px, 20px, 5px)") ==
            Some("rect(0, 10, 20, 5)"))
    }

    /** 单边 auto。 */
    @TestCase
    public func singleAuto(): Unit {
        let rect = SvgClipProperty.parse("rect(0, 10, auto, 0)")
        @Assert(rect.isSome())
        @Assert(rect.getOrThrow().top == Some(0.0))
        @Assert(rect.getOrThrow().right == Some(10.0))
        @Assert(rect.getOrThrow().bottom.isNone())
        @Assert(rect.getOrThrow().left == Some(0.0))
        let box = SvgClipProperty.toBounds(rect.getOrThrow())
        @Assert(box.y == 0.0)
        @Assert(box.height >= 1.0e9)
    }

    /** 非法输入返回 None，不抛异常。 */
    @TestCase
    public func invalidValues(): Unit {
        @Assert(SvgClipProperty.parse("rect(1px 2px)").isNone())
        @Assert(SvgClipProperty.parse("rect(a, b, c, d)").isNone())
        @Assert(SvgClipProperty.parse("circle(1,2,3)").isNone())
        @Assert(SvgClipProperty.parse("rect(1,2,3,4").isNone())
        @Assert(SvgClipProperty.normalize("rect(1,2,3,4,5)").isNone())
    }
}

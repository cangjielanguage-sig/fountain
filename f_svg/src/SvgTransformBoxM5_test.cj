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
public class SvgTransformBoxM5_test {
    /** 两个取值的大小写不敏感解析与 ToString。 */
    @TestCase
    public func parseAndRoundTrip(): Unit {
        @Assert(SvgTransformBox.fromName("fill-box") == Some(SvgTransformBox.FillBox))
        @Assert(SvgTransformBox.fromName("VIEW-BOX") == Some(SvgTransformBox.ViewBox))
        @Assert(SvgTransformBox.FillBox.toString() == "fill-box")
        @Assert(SvgTransformBox.ViewBox.toString() == "view-box")
        @Assert(SvgTransformBox.fromName("content-box").isNone())
    }

    /** 计算样式使用类型化 getter；未知值回退 ViewBox 并告警。 */
    @TestCase
    public func computedStyleUsesEnum(): Unit {
        let (document, tree, _) = m5ComputeStyles(
            "<svg xmlns=\"http://www.w3.org/2000/svg\">" +
            "<rect id=\"a\" transform-box=\"fill-box\"/>" +
            "<rect id=\"b\" transform-box=\"view-box\"/></svg>"
        )
        @Assert(m5StyleOf(tree, document.elementById("a")).transformBox() == SvgTransformBox.FillBox)
        @Assert(m5StyleOf(tree, document.elementById("b")).transformBox() == SvgTransformBox.ViewBox)

        let (invalidDocument, invalidTree, resolver) = m5ComputeStyles(
            "<svg xmlns=\"http://www.w3.org/2000/svg\">" +
            "<rect id=\"r\" transform-box=\"content-box\"/></svg>"
        )
        let style = m5StyleOf(invalidTree, invalidDocument.elementById("r"))
        @Assert(style.transformBox() == SvgTransformBox.ViewBox)
        var sawWarning = false
        for (warning in resolver.warnings) {
            if (warning.contains("transform-box")) {
                sawWarning = true
            }
        }
        @Assert(sawWarning)
    }
}

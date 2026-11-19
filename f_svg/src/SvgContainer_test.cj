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
public class SvgContainer_test {
    /** 十种容器类型的标签映射。 */
    @TestCase
    public func kindToTag(): Unit {
        let cases = [
            (SvgContainerKind.Group, "g"),
            (SvgContainerKind.Defs, "defs"),
            (SvgContainerKind.Symbol, "symbol"),
            (SvgContainerKind.Marker, "marker"),
            (SvgContainerKind.Pattern, "pattern"),
            (SvgContainerKind.ClipPath, "clipPath"),
            (SvgContainerKind.Mask, "mask"),
            (SvgContainerKind.Switch, "switch"),
            (SvgContainerKind.Anchor, "a"),
            (SvgContainerKind.ForeignObject, "foreignObject")
        ]
        for ((kind, tag) in cases) {
            let container = SvgContainer(kind)
            @Assert(container.kind == kind)
            @Assert(container.tag == tag)
            @Assert(container.namespace == SvgNamespaces.SVG)
        }
    }

    /** 由标签反查类型。 */
    @TestCase
    public func tagToKind(): Unit {
        @Assert(SvgContainerKind.fromTag("g") == Some(SvgContainerKind.Group))
        @Assert(SvgContainerKind.fromTag("clipPath") == Some(SvgContainerKind.ClipPath))
        @Assert(SvgContainerKind.fromTag("foreignObject") == Some(SvgContainerKind.ForeignObject))
        @Assert(SvgContainerKind.fromTag("a") == Some(SvgContainerKind.Anchor))
        @Assert(SvgContainerKind.fromTag("rect").isNone())
    }

    /** 容器可嵌套并保持父子关系。 */
    @TestCase
    public func nesting(): Unit {
        let root = SvgRoot()
        let defs = SvgContainer(SvgContainerKind.Defs)
        let group = SvgContainer(SvgContainerKind.Group)
        root.appendElement(defs)
        defs.appendElement(group)
        @Assert(group.elementPath() == "/svg[1]/defs[1]/g[1]")
        @Assert(defs.parent.getOrThrow() == root)
    }
}

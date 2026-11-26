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
public class SvgUse_test {
    /** href 双写法与几何属性。 */
    @TestCase
    public func useElement(): Unit {
        let bare = SvgUse()
        bare.setAttr("href", "#a")
        @Assert(bare.href == Some("#a"))

        let xlink = SvgUse()
        xlink.setAttr(SvgNamespaces.XLINK, "href", "#b")
        @Assert(xlink.href == Some("#b"))

        xlink.href = "#c"
        @Assert(xlink.attr(SvgNamespaces.XLINK, "href") == Some("#c"))
        @Assert(xlink.attr("href").isNone())

        xlink.x = SvgLength(1.0)
        xlink.y = SvgLength(2.0)
        xlink.width = SvgLength(3.0, unit: SvgLengthUnit.Px)
        xlink.height = SvgLength(4.0)
        @Assert(xlink.tag == "use")
        @Assert(xlink.x == Some(SvgLength(1.0)))
        @Assert(xlink.y == Some(SvgLength(2.0)))
        @Assert(xlink.width == Some(SvgLength(3.0, unit: SvgLengthUnit.Px)))
        @Assert(xlink.height == Some(SvgLength(4.0)))
    }
}

@Test
public class SvgImage_test {
    /** href 双写法与几何属性。 */
    @TestCase
    public func imageElement(): Unit {
        let image = SvgImage()
        @Assert(image.tag == "image")
        image.setAttr("href", "data:image/png;base64,AAAA")
        @Assert(image.href == Some("data:image/png;base64,AAAA"))
        let xlinkImage = SvgImage()
        xlinkImage.setAttr(SvgNamespaces.XLINK, "href", "#b")
        @Assert(xlinkImage.href == Some("#b"))

        image.x = SvgLength(0.0)
        image.y = SvgLength(0.0)
        image.width = SvgLength(10.0)
        image.height = SvgLength(20.0)
        @Assert(image.x == Some(SvgLength(0.0)))
        @Assert(image.height == Some(SvgLength(20.0)))

        image.preserveAspectRatio = SvgPreserveAspectRatio(SvgAspectAlign.XMaxYMax)
        @Assert(image.attr("preserveAspectRatio") == Some("xMaxYMax meet"))
        @Assert(image.preserveAspectRatio == Some(SvgPreserveAspectRatio(SvgAspectAlign.XMaxYMax)))
    }

    /** href 写入默认 xlink 形式。 */
    @TestCase
    public func hrefWrite(): Unit {
        let image = SvgImage()
        image.href = "pic.png"
        @Assert(image.attr(SvgNamespaces.XLINK, "href") == Some("pic.png"))
        @Assert(image.attr("href").isNone())
        @Assert(image.href == Some("pic.png"))
    }
}

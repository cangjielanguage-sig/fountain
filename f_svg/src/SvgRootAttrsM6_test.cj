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
public class SvgRootAttrsM6_test {
    /** baseProfile / version 缺省与显式值。 */
    @TestCase
    public func profileAndVersion(): Unit {
        let plain = SvgParser.parse("<svg xmlns=\"http://www.w3.org/2000/svg\"/>")
        @Assert(plain.baseProfile().isNone())
        @Assert(plain.version().isNone())
        @Assert(plain.zoomAndPan() == SvgZoomAndPan.Disable)

        let full = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" baseProfile=\"tiny\" version=\"1.1\" " +
            "zoomAndPan=\"magnify\"/>"
        )
        @Assert(full.baseProfile() == Some("tiny"))
        @Assert(full.version() == Some("1.1"))
        @Assert(full.zoomAndPan() == SvgZoomAndPan.Magnify)
    }

    /** zoomAndPan 大小写与非法值。 */
    @TestCase
    public func zoomAndPanParsing(): Unit {
        @Assert(SvgZoomAndPan.fromName("disable") == Some(SvgZoomAndPan.Disable))
        @Assert(SvgZoomAndPan.fromName("MAGNIFY") == Some(SvgZoomAndPan.Magnify))
        @Assert(SvgZoomAndPan.fromName("zoom").isNone())
        @Assert(SvgZoomAndPan.Disable.toString() == "disable")
        @Assert(SvgZoomAndPan.Magnify.toString() == "magnify")

        let document = SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" zoomAndPan=\"zoom\"/>"
        )
        @Assert(document.zoomAndPan() == SvgZoomAndPan.Disable)
        var found = false
        for (warning in document.warnings) {
            if (warning.contains("zoomAndPan")) {
                found = true
            }
        }
        @Assert(found)
    }
}

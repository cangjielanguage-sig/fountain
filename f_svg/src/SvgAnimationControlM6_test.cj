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
public class SvgAnimationControlM6_test {
    private func parse(inner: String): SvgDocument {
        SvgParser.parse(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20\" height=\"20\">" + inner + "</svg>"
        )
    }

    private func xOf(document: SvgDocument, id: String): String {
        match (document.elementById(id)) {
            case Some(element) => element.attr("x") ?? "missing"
            case None => "removed"
        }
    }

    /** 时间源：设置、负值钳制、NaN / Inf 拒绝。 */
    @TestCase
    public func timeSource(): Unit {
        let timeline = SvgTimeline(this.parse("<rect id=\"r\"/>"))
        timeline.setCurrentTime(3.0)
        @Assert(timeline.currentTime() == 3.0)
        timeline.setCurrentTime(-2.0)
        @Assert(timeline.currentTime() == 0.0)
        var threw = false
        try {
            timeline.setCurrentTime(Float64.NaN)
        } catch (_: SvgException) {
            threw = true
        }
        @Assert(threw)
        threw = false
        try {
            timeline.setCurrentTime(Float64.Inf)
        } catch (_: SvgException) {
            threw = true
        }
        @Assert(threw)
    }

    /** pause / unpause 冻结并恢复。 */
    @TestCase
    public func pauseAndUnpause(): Unit {
        let clock = SvgManualClock(time: 5.0)
        let timeline = SvgTimeline(this.parse("<rect id=\"r\"/>"), clock: clock)
        @Assert(timeline.currentTime() == 5.0)
        timeline.pause()
        clock.time = 9.0
        @Assert(timeline.currentTime() == 5.0)
        timeline.unpause()
        @Assert(timeline.currentTime() == 5.0)
        clock.time = 12.0
        @Assert(timeline.currentTime() == 8.0)
    }

    /** begin="indefinite" 显式触发。 */
    @TestCase
    public func indefiniteBegin(): Unit {
        let document = this.parse(
            "<rect id=\"r\" x=\"0\"><animate id=\"a\" attributeName=\"x\" values=\"0;10\" " +
            "dur=\"10s\" begin=\"indefinite\"/></rect>"
        )
        let timeline = SvgTimeline(document)
        timeline.setCurrentTime(50.0)
        timeline.begin("a")
        @Assert(this.xOf(timeline.sample(50.0), "r") == "0")
        @Assert(this.xOf(timeline.sample(55.0), "r") == "5")
        @Assert(timeline.animations().size == 1)
    }

    /** fireEvent 大小写、分号列表与 begin / end 分别生效。 */
    @TestCase
    public func fireEvent(): Unit {
        let document = this.parse(
            "<rect id=\"r\" x=\"0\"><animate id=\"a\" attributeName=\"x\" values=\"0;10\" " +
            "dur=\"10s\" begin=\"click; mouseover\" end=\"mouseout\" fill=\"freeze\"/></rect>"
        )
        let timeline = SvgTimeline(document)
        timeline.setCurrentTime(2.0)
        timeline.fireEvent("a", "CLICK")
        @Assert(this.xOf(timeline.sample(2.0), "r") == "0")
        @Assert(this.xOf(timeline.sample(7.0), "r") == "5")

        timeline.setCurrentTime(3.0)
        timeline.fireEvent("a", "mouseout")
        timeline.setCurrentTime(8.0)
        @Assert(this.xOf(timeline.sample(8.0), "r") == "10")

        let access = this.parse(
            "<rect id=\"r\" x=\"0\"><animate id=\"a\" attributeName=\"x\" values=\"0;10\" " +
            "dur=\"10s\" begin=\"accessKey(k); wallclock(2020)\"/></rect>"
        )
        let second = SvgTimeline(access)
        second.fireEvent("a", "accessKey(k)")
        second.fireEvent("a", "wallclock(2020)")
        @Assert(this.xOf(second.sample(0.0), "r") == "0")
    }

    /** end(id) 立即结束并按 fill="freeze" 保留末值。 */
    @TestCase
    public func explicitEnd(): Unit {
        let document = this.parse(
            "<rect id=\"r\" x=\"0\"><animate id=\"a\" attributeName=\"x\" values=\"0;100\" " +
            "dur=\"10s\" begin=\"0s\" fill=\"freeze\"/></rect>"
        )
        let timeline = SvgTimeline(document)
        @Assert(this.xOf(timeline.sample(5.0), "r") == "50")
        timeline.setCurrentTime(3.0)
        timeline.end("a")
        @Assert(this.xOf(timeline.sample(5.0), "r") == "100")
    }

    /** attributeType="CSS" 写内联样式且保留其他声明。 */
    @TestCase
    public func attributeTypeCss(): Unit {
        let document = this.parse(
            "<rect id=\"r\" style=\"stroke: green; fill: red\">" +
            "<animate attributeName=\"fill\" values=\"red;blue\" dur=\"10s\" begin=\"0s\" " +
            "attributeType=\"CSS\"/></rect>"
        )
        let snapshot = SvgTimeline(document).sample(9.9)
        let target = snapshot.elementById("r") ?? throw invalidValue("missing")
        let style = target.style ?? ""
        @Assert(style.contains("stroke: green"))
        let original = match (document.elementById("r")) {
            case Some(element) => element.style ?? ""
            case None => ""
        }
        @Assert(original == "stroke: green; fill: red")
    }

    /** min / max 钳制与非法组合。 */
    @TestCase
    public func minMax(): Unit {
        let document = this.parse(
            "<rect id=\"r\" x=\"0\"><animate attributeName=\"x\" values=\"0;100\" dur=\"10s\" " +
            "begin=\"0s\" max=\"2s\" fill=\"freeze\"/></rect>"
        )
        @Assert(this.xOf(SvgTimeline(document).sample(5.0), "r") == "100")

        let extended = this.parse(
            "<rect id=\"r\" x=\"0\"><animate attributeName=\"x\" values=\"0;100\" dur=\"10s\" " +
            "begin=\"0s\" min=\"15s\"/></rect>"
        )
        let extendedTimeline = SvgTimeline(extended)
        @Assert(this.xOf(extendedTimeline.sample(12.0), "r") == "100")

        let invalid = this.parse(
            "<rect id=\"r\" x=\"0\"><animate attributeName=\"x\" values=\"0;100\" dur=\"10s\" " +
            "begin=\"0s\" min=\"20s\" max=\"5s\"/></rect>"
        )
        let timeline = SvgTimeline(invalid)
        @Assert(this.xOf(timeline.sample(12.0), "r") == "0")
        var warned = false
        for (warning in timeline.warnings) {
            if (warning.contains("min") && warning.contains("max")) {
                warned = true
            }
        }
        @Assert(warned)
    }

    /** discard 到时移除目标，未到时保留。 */
    @TestCase
    public func discard(): Unit {
        let document = this.parse(
            "<rect id=\"r\" x=\"0\" width=\"10\" height=\"10\"/>" +
            "<discard begin=\"5s\" dur=\"1s\" href=\"#r\"/>"
        )
        let timeline = SvgTimeline(document)
        @Assert(timeline.sample(4.5).elementById("r").isSome())
        @Assert(timeline.sample(6.5).elementById("r").isNone())
        @Assert(document.elementById("r").isSome())
    }

    /** attributeType 非法值回退 XML 并 warning。 */
    @TestCase
    public func attributeTypeInvalid(): Unit {
        let document = this.parse(
            "<rect id=\"r\" x=\"0\"><animate attributeName=\"x\" values=\"0;100\" " +
            "dur=\"10s\" begin=\"0s\" attributeType=\"AUTO\"/></rect>"
        )
        let timeline = SvgTimeline(document)
        let snapshot = timeline.sample(9.0)
        let target = snapshot.elementById("r") ?? throw invalidValue("missing")
        @Assert(target.attr("x") == Some("90"))
        var warned = false
        for (warning in timeline.warnings) {
            if (warning.contains("attributeType")) {
                warned = true
            }
        }
        @Assert(warned)
    }

    /** 嵌套 discard 只处理最外层并 warning。 */
    @TestCase
    public func nestedDiscardWarns(): Unit {
        let document = this.parse(
            "<rect id=\"r\" x=\"0\" width=\"10\" height=\"10\"/>" +
            "<discard begin=\"1s\" dur=\"1s\" href=\"#r\">" +
            "<discard begin=\"1s\" dur=\"1s\" href=\"#r\"/></discard>"
        )
        let timeline = SvgTimeline(document)
        let snapshot = timeline.sample(2.5)
        @Assert(snapshot.elementById("r").isNone())
        var warned = false
        for (warning in timeline.warnings) {
            if (warning.contains("discard") && warning.contains("嵌套")) {
                warned = true
            }
        }
        @Assert(warned)
    }

    /** M5 既有动画在未调用新 API 时 sample(t) 输出不变。 */
    @TestCase
    public func m5SampleStability(): Unit {
        let document = this.parse(
            "<rect id=\"r\" x=\"0\"><animate attributeName=\"x\" values=\"0;10\" dur=\"10s\"/></rect>"
        )
        let timeline = SvgTimeline(document)
        @Assert(this.xOf(timeline.sample(5.0), "r") == "5")
        @Assert(this.xOf(timeline.sample(9.0), "r") == "9")
    }
}

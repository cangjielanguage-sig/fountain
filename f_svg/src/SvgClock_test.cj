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
public class SvgClock_test {
    /** 手动时钟读写与 sampleCurrent 使用时钟。 */
    @TestCase
    public func manualClock(): Unit {
        let clock = SvgManualClock(time: 1.5)
        @Assert(near(clock.now(), 1.5))
        clock.time = 2.5
        @Assert(near(clock.now(), 2.5))

        let document = SvgParser.parse(
            '<svg xmlns="http://www.w3.org/2000/svg"><rect id="r" width="10" height="10">' +
            '<animate attributeName="x" from="0" to="10" dur="2s"/>' +
            '</rect></svg>'
        )
        clock.time = 1.25
        let timeline = SvgTimeline(document, clock: clock)
        let snapshot = timeline.sampleCurrent()
        let rect = snapshot.elementById("r")
        match (rect) {
            case Some(value) => @Assert(near(parseNumericAttribute(value.attr("x")), 6.25))
            case None => @Fail("缺少目标元素")
        }
    }
}

internal func parseNumericAttribute(value: ?String): Float64 {
    match (value) {
        case Some(text) => tryParseSvgFloat(text) ?? -1.0
        case None => -1.0
    }
}

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
package fountain::fprobe.report

import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*

/** 15.1：默认类型、自定义类型、未知类型回退与告警。 */
@Test
public class ChartSelector_test {
    @TestCase
    public func defaultsFollowSpec(): Unit {
        let selector = ChartSelector(lookup: {_ => None<String>}, warn: {_ => ()})

        @Assert(selector.select("cpu.usagePercent"), "line")
        @Assert(selector.select("memory.usedPercent"), "area")
        @Assert(selector.select("disk.usedPercent"), "bar")
        @Assert(selector.select("network.rxBps"), "line")
        @Assert(selector.select("service.latencyMs"), "line")
        @Assert(selector.select("custom.metric"), "line")
    }

    @TestCase
    public func configuredTypeWins(): Unit {
        let selector = ChartSelector(
            lookup: {key => if (key == "probe_chart_cpu_usagePercent") {
                Some("bar")
            } else {
                None<String>
            }},
            warn: {_ => ()})

        @Assert(selector.select("cpu.usagePercent"), "bar")
    }

    @TestCase
    public func unsupportedTypeFallsBackToLineWithWarning(): Unit {
        let warnings = ArrayList<String>()
        let selector = ChartSelector(
            lookup: {key => if (key == "probe_chart_cpu_usagePercent") {
                Some("sankey")
            } else {
                None<String>
            }},
            warn: {message => warnings.add(message)})

        @Assert(selector.select("cpu.usagePercent"), "line")
        @Assert(warnings.size, 1)
        @Assert(warnings[0].contains("sankey"))
        @Assert(warnings[0].contains("probe_chart_cpu_usagePercent"))
    }

    @TestCase
    public func configKeyReplacesDots(): Unit {
        @Assert(ChartSelector.configKey("cpu.usagePercent"), "probe_chart_cpu_usagePercent")
        @Assert(ChartSelector.configKey("network.rxBps"), "probe_chart_network_rxBps")
    }
}

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

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_svg.SvgParser
import fountain::fprobe.collect.topology.{TopologyDevice, TopologyLink, TopologySample}

/** 15.6：确定性环形布局、设备与链路绘制、空拓扑返回 None。 */
@Test
public class TopologyRenderer_test {
    @TestCase
    public func sameInputProducesSameSvg(): Unit {
        let sample = TopologySample([
            TopologyDevice("sw-b", "10.0.0.2", ["eth1"]),
            TopologyDevice("sw-a", "10.0.0.1", ["eth0"]),
            TopologyDevice("sw-c", "10.0.0.3", ["eth2"])
        ], [
            TopologyLink("sw-a", "sw-b", "eth0", "eth1"),
            TopologyLink("sw-b", "sw-c", "eth1", "eth2")
        ], "")

        let first = match (TopologyRenderer.render(sample)) {
            case Some(svg) => svg
            case None => ""
        }
        let second = match (TopologyRenderer.render(sample)) {
            case Some(svg) => svg
            case None => ""
        }

        @Assert(!first.isEmpty())
        @Assert(first, second)
        @Assert(first.contains("sw-a"))
        @Assert(first.contains("sw-b"))
        @Assert(first.contains("sw-c"))
        @Assert(first.contains("<line"))
        @Assert(SvgParser.parse(first).root.tag, "svg")
    }

    @TestCase
    public func emptyTopologyReturnsNone(): Unit {
        let sample = TopologySample([], [], "未配置")
        @Assert(TopologyRenderer.render(sample).isNone())
    }
}

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
package fountain::f_chart

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.json.*

@Test
public class HiveChart_test {
    private func draw(json: String): String {
        HiveChart().draw(JsonValue.fromStr(json).asObject())
    }

    private func count(svg: String, needle: String): Int64 {
        var total = 0
        var from = 0
        while (let Some(index) <- svg.indexOf(needle, from)) {
            total++
            from = index + needle.toArray().size
        }
        total
    }

    private let sample: String = """
{
  "type": "hive",
  "title": "技能关系",
  "width": 760,
  "height": 520,
  "groupField": "group",
  "nodeRadius": 18,
  "clusterGap": 80,
  "nodes": [
    { "id": "cangjie", "name": "仓颉", "group": "语言" },
    { "id": "go", "name": "Go", "group": "语言" },
    { "id": "sql", "name": "SQL", "group": "数据" },
    { "id": "redis", "name": "Redis", "group": "数据" },
    { "id": "k8s", "name": "K8s", "group": "运维" }
  ],
  "links": [
    { "source": "cangjie", "target": "sql", "value": 2 },
    { "source": "go", "target": "redis", "value": 3 },
    { "source": "sql", "target": "redis", "value": 2 },
    { "source": "redis", "target": "k8s", "value": 1 }
  ]
}
"""

    /** 五个节点与四条连线。 */
    @TestCase
    public func drawsNodesAndLinks(): Unit {
        let svg = draw(sample)
        @Assert(count(svg, "class=\"hive-node\"") == 5)
        @Assert(count(svg, "class=\"hive-label\"") == 5)
        @Assert(count(svg, "class=\"hive-link\"") == 4)
    }

    /** 默认节点半径 10。 */
    @TestCase
    public func usesDefaultRadius(): Unit {
        let svg = draw("""
{
  "type": "hive",
  "nodes": [
    { "id": "a", "name": "A", "group": "g" },
    { "id": "b", "name": "B", "group": "g" }
  ],
  "links": [ { "source": "a", "target": "b" } ]
}
""")
        @Assert(svg.contains("r=\"10"))
    }

    /** 非正半径。 */
    @TestCase
    public func rejectsInvalidRadius(): Unit {
        try {
            draw("""
{
  "type": "hive",
  "nodeRadius": 0,
  "nodes": [ { "id": "a" } ],
  "links": [ { "source": "a", "target": "a" } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 非正簇间距。 */
    @TestCase
    public func rejectsInvalidClusterGap(): Unit {
        try {
            draw("""
{
  "type": "hive",
  "clusterGap": 0,
  "nodes": [ { "id": "a" } ],
  "links": [ { "source": "a", "target": "a" } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 未知端点。 */
    @TestCase
    public func rejectsUnknownEndpoint(): Unit {
        try {
            draw("""
{
  "type": "hive",
  "nodes": [ { "id": "a" } ],
  "links": [ { "source": "a", "target": "missing" } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 重复节点 id。 */
    @TestCase
    public func rejectsDuplicateNodeId(): Unit {
        try {
            draw("""
{
  "type": "hive",
  "nodes": [ { "id": "a" }, { "id": "a" } ],
  "links": [ { "source": "a", "target": "a" } ]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 空节点。 */
    @TestCase
    public func rejectsEmptyNodes(): Unit {
        try {
            draw("""
{
  "type": "hive",
  "nodes": [],
  "links": []
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 类型不匹配。 */
    @TestCase
    public func rejectsTypeMismatch(): Unit {
        try {
            draw("""
{
  "type": "chord",
  "nodes": [],
  "links": []
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.UnsupportedChart)
        }
    }

    /** 相同输入输出一致。 */
    @TestCase
    public func deterministic(): Unit {
        @Assert(draw(sample) == draw(sample))
    }
}

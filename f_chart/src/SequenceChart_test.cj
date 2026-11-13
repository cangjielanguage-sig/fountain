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
import fountain::f_svg.SvgParser

@Test
public class SequenceChart_test {
    private func draw(json: String): String {
        SequenceChart().draw(JsonValue.fromStr(json).asObject())
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

    /** 三个参与者 + 生命线。 */
    @TestCase
    public func drawsParticipants(): Unit {
        let svg = draw("""
{
  "type": "sequence",
  "participants": [
    { "id": "u", "name": "用户" },
    { "id": "a", "name": "客户端" },
    { "id": "s", "name": "服务端" }
  ],
  "messages": [{ "from": "u", "to": "a", "text": "请求" }]
}
""")
        @Assert(count(svg, "class=\"participant\"") == 3)
        @Assert(count(svg, "class=\"lifeline\"") == 3)
    }

    /** 四条消息。 */
    @TestCase
    public func drawsMessages(): Unit {
        let svg = draw("""
{
  "type": "sequence",
  "participants": [
    { "id": "u", "name": "用户" },
    { "id": "a", "name": "客户端" }
  ],
  "messages": [
    { "from": "u", "to": "a", "text": "一" },
    { "from": "a", "to": "u", "text": "二" },
    { "from": "u", "to": "a", "text": "三" },
    { "from": "a", "to": "u", "text": "四" }
  ]
}
""")
        @Assert(count(svg, "class=\"message\"") == 4)
    }

    /** 返回消息虚线。 */
    @TestCase
    public func drawsReturnDashed(): Unit {
        let svg = draw("""
{
  "type": "sequence",
  "participants": [
    { "id": "u", "name": "用户" },
    { "id": "a", "name": "客户端" }
  ],
  "messages": [
    { "from": "u", "to": "a", "text": "请求" },
    { "from": "a", "to": "u", "text": "响应", "type": "return" }
  ]
}
""")
        @Assert(count(svg, "stroke-dasharray") >= 2)
    }

    /** 消息文本。 */
    @TestCase
    public func drawsMessageLabels(): Unit {
        let svg = draw("""
{
  "type": "sequence",
  "participants": [{ "id": "u", "name": "用户" }, { "id": "a", "name": "客户端" }],
  "messages": [{ "from": "u", "to": "a", "text": "登录请求" }]
}
""")
        @Assert(svg.contains("登录请求"))
    }

    /** 悬空端点。 */
    @TestCase
    public func rejectsDanglingEndpoint(): Unit {
        try {
            draw("""
{
  "type": "sequence",
  "participants": [{ "id": "u", "name": "用户" }],
  "messages": [{ "from": "u", "to": "missing", "text": "请求" }]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.InvalidValue)
        }
    }

    /** 缺 participants。 */
    @TestCase
    public func rejectsMissingParticipants(): Unit {
        try {
            draw("""
{
  "type": "sequence",
  "messages": []
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.MissingField)
        }
    }

    /** 缺 messages。 */
    @TestCase
    public func rejectsMissingMessages(): Unit {
        try {
            draw("""
{
  "type": "sequence",
  "participants": [{ "id": "u", "name": "用户" }]
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.MissingField)
        }
    }

    /** 类型不匹配。 */
    @TestCase
    public func rejectsWrongType(): Unit {
        try {
            draw("""
{
  "type": "flowchart",
  "participants": [{ "id": "u", "name": "用户" }],
  "messages": []
}
""")
            @Assert(false)
        } catch (error: ChartException) {
            @Assert(error.kind == ChartErrorKind.UnsupportedChart)
        }
    }

    /** 确定性。 */
    @TestCase
    public func isDeterministic(): Unit {
        let json = """
{
  "type": "sequence",
  "participants": [{ "id": "u", "name": "用户" }, { "id": "a", "name": "客户端" }],
  "messages": [{ "from": "u", "to": "a", "text": "请求" }]
}
"""
        @Assert(draw(json) == draw(json))
    }

    /** 可解析。 */
    @TestCase
    public func outputIsParseable(): Unit {
        let svg = draw("""
{
  "type": "sequence",
  "participants": [{ "id": "u", "name": "用户" }],
  "messages": [{ "from": "u", "to": "u", "text": "自调用" }]
}
""")
        @Assert(SvgParser.parse(svg).root.tag == "svg")
    }
}

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
package fountain::fprobe.llm

import std.unittest.*
import std.unittest.testmacro.*

/** 16.2：合法 JSON、Markdown 围栏、纯文本兜底。 */
@Test
public class AdviceParser_test {
    @TestCase
    public func parsesPlainJson(): Unit {
        let text = "{\"summary\":\"CPU 高\",\"problems\":[\"CPU 持续高\"],\"solutions\":[{\"title\":\"临时静音\",\"action\":\"mute\",\"risk\":\"低\"}]}"
        let advice = AdviceParser.parse(text)

        @Assert(advice.summary, "CPU 高")
        @Assert(advice.problems.size, 1)
        @Assert(advice.problems[0], "CPU 持续高")
        @Assert(advice.solutions.size, 1)
        @Assert(advice.solutions[0].title, "临时静音")
        @Assert(advice.solutions[0].action, "mute")
        @Assert(advice.solutions[0].risk, "低")
    }

    @TestCase
    public func stripsMarkdownFence(): Unit {
        let text = "```json\n{\"summary\":\"磁盘将满\",\"problems\":[\"根分区 95%\"],\"solutions\":[{\"title\":\"清理日志\",\"action\":\"none\",\"risk\":\"中\"}]}\n```"
        let advice = AdviceParser.parse(text)

        @Assert(advice.summary, "磁盘将满")
        @Assert(advice.problems.size, 1)
        @Assert(advice.solutions[0].action, "none")
    }

    @TestCase
    public func plainTextFallsBackToSummary(): Unit {
        let text = "模型暂时不可用，请人工检查 CPU 与内存。"
        let advice = AdviceParser.parse(text)

        @Assert(advice.summary, text)
        @Assert(advice.problems.isEmpty())
        @Assert(advice.solutions.isEmpty())
    }

    @TestCase
    public func jsonMissingSummaryFallsBackToOriginal(): Unit {
        let text = "{\"problems\":[\"x\"],\"solutions\":[]}"
        let advice = AdviceParser.parse(text)

        @Assert(advice.summary, text)
        @Assert(advice.problems.isEmpty())
    }
}

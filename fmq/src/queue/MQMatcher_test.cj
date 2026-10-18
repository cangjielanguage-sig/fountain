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
package fountain::fmq.queue

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.*
import fountain::f_data.macros.*
import fountain::f_mq.base.{MQFilter, MQMessageRecord}

@DataAssist[props fields]
public class MatchBody {
    private var level: Int64 = 0
    private var enabled: Bool = false

    public init() {}

    public init(level: Int64, enabled: Bool) {
        this.level = level
        this.enabled = enabled
    }
}

@Test
class MQMatcherTest {
    private static func record(topic: String, tags: Array<String>, body: Data): Array<Byte> {
        MQMessageRecord.encode(topic, tags, "m", body)
    }

    private static func view(topic: String, tags!: Array<String> = [], filter!: String = ''): MQSubscriptionView {
        MQSubscriptionView("s", topic, tags, MQFilter.compile(filter), false)
    }

    @TestCase
    public func topicMustMatchExactly(): Unit {
        let value = record("/a/bc", [], 1i64.toData())
        @Assert(!MQMatcher.matches(view("/a/b"), value))
        @Assert(MQMatcher.matches(view("/a/bc"), value))
    }

    @TestCase
    public func tagsAreSubsetAndOrderIndependent(): Unit {
        let value = record("/t", ["b", "c", "a"], 1i64.toData())
        @Assert(MQMatcher.matches(view("/t", tags: ["a", "b"]), value))
        @Assert(!MQMatcher.matches(view("/t", tags: ["a", "x"]), value))
        // 空订阅 tags 不限制
        @Assert(MQMatcher.matches(view("/t"), value))
        // 重复的订阅 tags 不影响
        @Assert(MQMatcher.matches(view("/t", tags: ["a", "a"]), value))
        @Assert(MQMatcher.matchesTags(["a", "b"], ["b", "c", "a"]))
        @Assert(!MQMatcher.matchesTags(["a"], ["b"]))
        @Assert(MQMatcher.matchesTags([], []))
    }

    @TestCase
    public func emptyFilterAlwaysMatches(): Unit {
        let value = record("/t", [], MatchBody(1, true).toData())
        @Assert(MQMatcher.matches(view("/t"), value))
        @Assert(MQMatcher.matches(view("/t", filter: ""), value))
    }

    @TestCase
    public func filterDecidesDelivery(): Unit {
        // 谓词表达式作用于集合 BODY（与 f_data.path 语义一致）
        let high: Array<MatchBody> = [MatchBody(3, true)]
        let low: Array<MatchBody> = [MatchBody(1, true)]
        let highRecord = record("/t", [], high.toData())
        let lowRecord = record("/t", [], low.toData())
        let sub = view("/t", filter: "$[?(@.level > 2)]")
        @Assert(MQMatcher.matches(sub, highRecord))
        @Assert(!MQMatcher.matches(sub, lowRecord))
    }

    @TestCase
    public func booleanFilter(): Unit {
        let enabled = record("/t", [], MatchBody(1, true).toData())
        let disabled = record("/t", [], MatchBody(1, false).toData())
        let sub = view("/t", filter: "$.enabled")
        @Assert(MQMatcher.matches(sub, enabled))
        @Assert(!MQMatcher.matches(sub, disabled))
    }

    @TestCase
    public func undecodableBodyDoesNotMatch(): Unit {
        // 截断记录：topic/tags 可解，BODY 不可解；带 filter 的订阅必须不匹配
        let full = record("/t", [], MatchBody(3, true).toData())
        let truncated = full[0..full.size - 3]
        let sub = view("/t", filter: "$.level")
        @Assert(!MQMatcher.matches(sub, truncated))
        // 无 filter 时只看 topic/tags
        @Assert(MQMatcher.matches(view("/t"), truncated))
    }
}

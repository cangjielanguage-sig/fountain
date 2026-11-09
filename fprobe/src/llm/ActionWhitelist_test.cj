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

import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*

/** 16.5：白名单动作表驱动，mute 使用配置时长。 */
@Test
public class ActionWhitelist_test {
    @TestCase
    public func whitelistActionsAreExecuted(): Unit {
        let acked = ArrayList<String>()
        let muted = ArrayList<(String, Int64)>()
        let reports = ArrayList<Int64>()
        let whitelist = ActionWhitelist(
            ack: {rule => acked.add(rule)},
            mute: {rule: String, until: Int64 => muted.add((rule, until))},
            report: {=> reports.add(1)},
            nowMs: {=> 1000},
            muteSeconds: 600)

        @Assert(whitelist.apply(ReplyDecision.APPROVE, "ack", "cpu-high"), WhitelistResult.ACKED)
        @Assert(acked.size, 1)
        @Assert(acked[0], "cpu-high")

        @Assert(whitelist.apply(ReplyDecision.APPROVE, "mute", "cpu-high"), WhitelistResult.MUTED)
        @Assert(muted.size, 1)
        @Assert(muted[0][0], "cpu-high")
        @Assert(muted[0][1], 601000)

        @Assert(whitelist.apply(ReplyDecision.APPROVE, "report", ""), WhitelistResult.REPORTED)
        @Assert(reports.size, 1)

        @Assert(whitelist.apply(ReplyDecision.APPROVE, "none", ""), WhitelistResult.NONE)
        @Assert(acked.size, 1)
        @Assert(muted.size, 1)
        @Assert(reports.size, 1)
    }

    @TestCase
    public func nonWhitelistedActionIsNotExecuted(): Unit {
        let acked = ArrayList<String>()
        let muted = ArrayList<(String, Int64)>()
        let reports = ArrayList<Int64>()
        let whitelist = ActionWhitelist(
            ack: {rule => acked.add(rule)},
            mute: {rule: String, until: Int64 => muted.add((rule, until))},
            report: {=> reports.add(1)},
            nowMs: {=> 1000},
            muteSeconds: 600)

        @Assert(whitelist.apply(ReplyDecision.APPROVE, "restart-service", "cpu-high"),
            WhitelistResult.UNSUPPORTED)
        @Assert(acked.isEmpty())
        @Assert(muted.isEmpty())
        @Assert(reports.size, 0)
    }

    @TestCase
    public func rejectDoesNothing(): Unit {
        let muted = ArrayList<(String, Int64)>()
        let reports = ArrayList<Int64>()
        let whitelist = ActionWhitelist(
            ack: {_ => ()},
            mute: {rule: String, until: Int64 => muted.add((rule, until))},
            report: {=> reports.add(1)},
            nowMs: {=> 1000},
            muteSeconds: 600)

        @Assert(whitelist.apply(ReplyDecision.REJECT, "mute", "cpu-high"), WhitelistResult.REJECTED)
        @Assert(whitelist.apply(ReplyDecision.REJECT, "report", ""), WhitelistResult.REJECTED)
        @Assert(muted.isEmpty())
        @Assert(reports.size, 0)
    }

    @TestCase
    public func actionIsCaseInsensitiveAndTrimmed(): Unit {
        let muted = ArrayList<(String, Int64)>()
        let whitelist = ActionWhitelist(
            ack: {_ => ()},
            mute: {rule: String, until: Int64 => muted.add((rule, until))},
            report: {=> ()},
            nowMs: {=> 0},
            muteSeconds: 10)

        @Assert(whitelist.apply(ReplyDecision.APPROVE, "  MuTe  ", "r1"), WhitelistResult.MUTED)
        @Assert(muted[0][1], 10000)
    }
}

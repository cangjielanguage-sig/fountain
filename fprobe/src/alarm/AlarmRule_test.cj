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
package fountain::fprobe.alarm

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_config.Config
import fountain::f_probe.{ProbeErrorCode, ProbeException}

private func withAlarmRules(value: String, body: () -> Unit): Unit {
    let old = Config.getString("probe_alarmRules")
    Config.set([("probe_alarmRules", value)])
    try {
        body()
    } finally {
        match (old) {
            case Some(text) => Config.set([("probe_alarmRules", text)])
            case None => Config.remove("probe_alarmRules")
        }
    }
}

/** 10.1：规则 DTO 与 `probe_alarmRules` 解析。 */
@Test
public class AlarmRuleParse_test {
    @TestCase
    public func validArrayIsParsed(): Unit {
        let text = '''
[
  {"name":"cpu-high","kind":"cpu","path":"$.usagePercent","op":"gt","threshold":85,"forSeconds":60,"level":"critical"},
  {"name":"mem-low","kind":"memory","path":"$.freePercent","op":"lt","threshold":5,"forSeconds":0,"level":"warning"}
]
'''
        let rules = AlarmRule.parse(text)
        @Assert(rules.size, 2)
        @Assert(rules[0].name, "cpu-high")
        @Assert(rules[0].kind, "cpu")
        @Assert(rules[0].path, "$.usagePercent")
        @Assert(rules[0].op, "gt")
        @Assert(rules[0].threshold, 85.0)
        @Assert(rules[0].forSeconds, 60)
        @Assert(rules[0].level, "critical")
        @Assert(rules[1].name, "mem-low")
        @Assert(rules[1].threshold, 5.0)
    }

    @TestCase
    public func loadReadsConfig(): Unit {
        withAlarmRules('[{"name":"n","kind":"k","path":"$.v","op":"eq","threshold":1,"forSeconds":0,"level":"warning"}]') {
            let rules = AlarmRule.load()
            @Assert(rules.size, 1)
            @Assert(rules[0].name, "n")
        }
        // 未配置时为空数组，而不是启动失败
        let old = Config.getString("probe_alarmRules")
        Config.remove("probe_alarmRules")
        try {
            @Assert(AlarmRule.load().isEmpty())
        } finally {
            match (old) {
                case Some(text) => Config.set([("probe_alarmRules", text)])
                case None => ()
            }
        }
    }

    @TestCase
    public func nonArrayIsRejected(): Unit {
        var caught = false
        try {
            AlarmRule.parse('{"name":"one"}')
        } catch (e: ProbeException) {
            caught = true
            @Assert(e.code, ProbeErrorCode.CONFIG)
            @Assert(e.message.contains("数组"))
        }
        @Assert(caught)
    }

    @TestCase
    public func invalidJsonIsRejected(): Unit {
        var caught = false
        try {
            AlarmRule.parse("not-json")
        } catch (e: ProbeException) {
            caught = true
            @Assert(e.code, ProbeErrorCode.CONFIG)
        }
        @Assert(caught)
    }

    @TestCase
    public func missingFieldReportsRuleIndex(): Unit {
        var caught = false
        try {
            AlarmRule.parse('[{"name":"no-path","kind":"cpu","op":"gt","threshold":1,"forSeconds":0,"level":"warning"}]')
        } catch (e: ProbeException) {
            caught = true
            @Assert(e.code, ProbeErrorCode.CONFIG)
            @Assert(e.message.contains("第 1 条"))
            @Assert(e.message.contains("path"))
        }
        @Assert(caught)
    }

    @TestCase
    public func invalidOpReportsRuleIndex(): Unit {
        var caught = false
        try {
            AlarmRule.parse('[' +
                '{"name":"ok","kind":"cpu","path":"$.v","op":"gt","threshold":1,"forSeconds":0,"level":"warning"},' +
                '{"name":"bad","kind":"cpu","path":"$.v","op":"between","threshold":1,"forSeconds":0,"level":"warning"}]')
        } catch (e: ProbeException) {
            caught = true
            @Assert(e.code, ProbeErrorCode.CONFIG)
            @Assert(e.message.contains("第 2 条"))
            @Assert(e.message.contains("op"))
        }
        @Assert(caught)
    }

    @TestCase
    public func nonObjectItemIsRejected(): Unit {
        var caught = false
        try {
            AlarmRule.parse('[1,2]')
        } catch (e: ProbeException) {
            caught = true
            @Assert(e.message.contains("第 1 条"))
        }
        @Assert(caught)
    }
}

/** 10.2：六种比较按阈值语义判定。 */
@Test
public class AlarmOp_test {
    @TestCase
    public func allOperatorsMatchExpectedValues(): Unit {
        let cases: Array<(AlarmOp, Float64, Float64, Bool)> = [
            (AlarmOp.Gt, 90.0, 85.0, true),
            (AlarmOp.Gt, 85.0, 85.0, false),
            (AlarmOp.Gte, 85.0, 85.0, true),
            (AlarmOp.Gte, 84.9, 85.0, false),
            (AlarmOp.Lt, 4.0, 5.0, true),
            (AlarmOp.Lt, 5.0, 5.0, false),
            (AlarmOp.Lte, 5.0, 5.0, true),
            (AlarmOp.Lte, 5.1, 5.0, false),
            (AlarmOp.Eq, 5.0, 5.0, true),
            (AlarmOp.Eq, 5.1, 5.0, false),
            (AlarmOp.Ne, 5.1, 5.0, true),
            (AlarmOp.Ne, 5.0, 5.0, false)
        ]
        for ((op, value, threshold, expected) in cases) {
            @Assert(op.matches(value, threshold), expected)
        }
    }

    @TestCase
    public func operatorsParseFromNames(): Unit {
        @Assert(AlarmOp.parse("gt").getOrThrow(), AlarmOp.Gt)
        @Assert(AlarmOp.parse("GTE").getOrThrow(), AlarmOp.Gte)
        @Assert(AlarmOp.parse("lt").getOrThrow(), AlarmOp.Lt)
        @Assert(AlarmOp.parse("lte").getOrThrow(), AlarmOp.Lte)
        @Assert(AlarmOp.parse("eq").getOrThrow(), AlarmOp.Eq)
        @Assert(AlarmOp.parse("ne").getOrThrow(), AlarmOp.Ne)
        @Assert(AlarmOp.parse("between").isNone())
    }
}

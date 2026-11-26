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
package fountain::f_rule.test

import std.runtime.gc
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_rule.engine.RuleEngine
import fountain::f_rule.fact.TypeTag
import fountain::f_rule.rule.RuleSet

/**
 * 内存门禁（`doc/09-testing.md` §5 B-05）。
 *
 * 口径：构建 1000 规则、打开一个会话并插入 10000 条事实后，读取进程 `VmRSS`。
 * 报告里同时给出基线与增量，门禁按绝对 RSS 判定（< 512MB）。
 */
@Tag[perf]
@Test
class PerfMemory_test {
    /** B-05：1000 规则 / 10000 事实 RSS < 512MB。 */
    @Tag[perf, b05]
    @TestCase
    public func b05ResidentMemoryWithinGate(): Unit {
        let baseline = PerfSupport.rssBytes()
        gc()
        let afterGc = PerfSupport.rssBytes()
        let ruleSet = PerfFixture.ruleSet("perf-b05", 1000)
        let engine = RuleEngine(ruleSet)
        let session = engine.session("b05")
        for (fact in PerfFixture.facts(10000)) {
            let _ = session.assert(TypeTag.DEFAULT_SPACE, fact)
        }
        let used = PerfSupport.rssBytes()
        println("[BENCH] B-05 RSS baseline=${baseline} afterGc=${afterGc} used=${used} " +
            "delta=${used - afterGc} bytes")
        PerfSupport.requireBelow("B-05 RSS", used, PerfGate.B05_RSS_BYTES)
    }
}

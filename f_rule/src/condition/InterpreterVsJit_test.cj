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
package fountain::f_rule.condition

import std.collection.HashMap
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_jit.*
import fountain::f_rule.fact.*

/**
 * JIT 与内置解释器的差分（用例 I-03，`doc/09-testing.md` §4.2）。
 *
 * 同一批源码在 `JitPreferred` 与 `Interpreted` 下必须逐条一致；不一致时输出
 * 表达式与输入，便于定位是哪一侧的语义漂移。
 */
@Test
class InterpreterVsJit_test {
    private static let sources = [
        "o.amount > 200 && o.level >= 3",
        "o.amount <= 100 || o.level == 5",
        "!(o.amount < 50)",
        "o.amount >= 300 && o.level < 4"
    ]

    private func compiler(): Compiler {
        let c = Compiler()
        c.registerType<JitOrder>()
        c
    }

    private func orders(): Array<JitOrder> {
        [
            JitOrder("A", 500, 3, "vip"),
            JitOrder("B", 100, 5, "normal"),
            JitOrder("C", 300, 2, "vip"),
            JitOrder("D", 49, 1, "normal"),
            JitOrder("E", 200, 3, "vip")
        ]
    }

    private func bindings(order: JitOrder): HashMap<String, Fact> {
        let map = HashMap<String, Fact>()
        map["o"] = TypedFact(order, jitOrderSchema())
        map
    }

    /** 逐个表达式、逐条事实比对 JIT 与解释器结果。 */
    @TestCase
    public func bothModesAgreeOnEveryInput(): Unit {
        let compile = compiler()
        for (source in InterpreterVsJit_test.sources) {
            let jit = JitExpression.ofExpression(source, [("o", "JitOrder")], compile)
            let interpreted = JitExpression.interpreted(source, ["o"])
            for (order in orders()) {
                let facts = bindings(order)
                let jitResult = jit.eval(facts)
                let interpretedResult = interpreted.eval(facts)
                if (jitResult != interpretedResult) {
                    @Fail("差分不一致: ${source} on ${order.id}: jit=${jitResult} interpreted=${interpretedResult}")
                }
            }
        }
    }
}

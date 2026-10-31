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

import std.collection.ArrayList
import fountain::f_rule.condition.{JoinConstraint, Operator, Pattern}
import fountain::f_rule.fact.DynamicFact
import fountain::f_rule.rule.Rule

/**
 * 固定种子的规则/事实生成器（`doc/09-testing.md` §4.1）。
 *
 * 默认种子 `20261031`，保证差分失败可复现。生成器自己实现 LCG 而不是依赖
 * `std.random`：种子与序列完全由本类控制，跨平台一致。
 */
public class PropertyGen {
    private var state: Int64

    public init(seed!: Int64 = 20261031) {
        this.state = seed
    }

    /** 0..bound-1 的确定性伪随机数。 */
    public func next(bound: Int64): Int64 {
        state = (state * 1103515245 + 12345) % 2147483648
        if (bound <= 0) {
            return 0
        }
        (state / 65536) % bound
    }

    /** 生成 `count` 条 `GenFact` 动态事实（字段 amount / level / code）。 */
    public func facts(count: Int64): Array<DynamicFact> {
        let out = ArrayList<DynamicFact>()
        var i: Int64 = 0
        while (i < count) {
            let fact = DynamicFact("GenFact")
            fact.set("amount", next(1000))
            fact.set("level", next(6))
            fact.set("code", if (next(2) == 0) { "A" } else { "B" })
            out.add(fact)
            i += 1
        }
        out.toArray()
    }

    /** 生成 `count` 条单/双模式规则，至少一条约束。 */
    public func rules(count: Int64, space!: String = "default"): Array<Rule> {
        let out = ArrayList<Rule>()
        var i: Int64 = 0
        while (i < count) {
            let builder = Rule.builder("G${i}")
                .facts(space)
                .salience(next(10))
                .addPattern(Pattern("GenFact", "o").constrain("amount", Operator.Ge, next(500)))
            if (next(2) == 0) {
                let _ = builder.addPattern(Pattern("GenFact", "u")
                    .constrain("level", Operator.Le, next(6)))
                let _ = builder.join(JoinConstraint("o", "amount", Operator.Gt, "u", "amount"))
            }
            out.add(builder.build())
            i += 1
        }
        out.toArray()
    }

    /**
     * 随机事实：字段可能缺失（覆盖 `IsNull` 与 `Unknown` 的分支）。
     *
     * 与 [facts] 的区别是字段不保证齐全，用于差分测试。
     */
    public func randomFacts(count: Int64): Array<DynamicFact> {
        let out = ArrayList<DynamicFact>()
        var i: Int64 = 0
        while (i < count) {
            let fact = DynamicFact("GenFact")
            if (next(6) != 0) {
                fact.set("amount", next(20))
            }
            if (next(6) != 0) {
                fact.set("level", next(6))
            }
            if (next(6) != 0) {
                fact.set("code", if (next(2) == 0) { "A" } else { "B" })
            }
            out.add(fact)
            i += 1
        }
        out.toArray()
    }

    /**
     * 随机规则：1~5 个模式、每模式 0~4 条约束、可选跨模式 join。
     *
     * 覆盖等值/范围/In/Between/IsNull/Contains，供 Rete 与朴素匹配差分。
     */
    public func randomRules(count: Int64, space!: String = "default"): Array<Rule> {
        let out = ArrayList<Rule>()
        var i: Int64 = 0
        while (i < count) {
            let patternCount = 1 + next(5)
            let builder = Rule.builder("G${i}").facts(space).salience(next(10))
            var j: Int64 = 0
            while (j < patternCount) {
                let binding = "b${j}"
                let pattern = Pattern("GenFact", binding)
                let constraintCount = next(5)
                var k: Int64 = 0
                while (k < constraintCount) {
                    addConstraint(pattern)
                    k += 1
                }
                let _ = builder.addPattern(pattern)
                if (j > 0 && next(3) != 0) {
                    let previous = next(j)
                    let _ = builder.join(JoinConstraint("b${previous}", "amount",
                        randomJoinOp(), binding, "amount"))
                }
                j += 1
            }
            out.add(builder.build())
            i += 1
        }
        out.toArray()
    }

    private func randomJoinOp(): Operator {
        match (next(5)) {
            case 0 => Operator.Eq
            case 1 => Operator.Gt
            case 2 => Operator.Ge
            case 3 => Operator.Lt
            case _ => Operator.Le
        }
    }

    private func addConstraint(pattern: Pattern): Unit {
        match (next(9)) {
            case 0 => let _ = pattern.constrain("amount", Operator.Eq, next(20))
            case 1 => let _ = pattern.constrain("amount", Operator.Ge, next(20))
            case 2 => let _ = pattern.constrain("level", Operator.Le, next(6))
            case 3 => let _ = pattern.constrain("level", Operator.Gt, next(6))
            case 4 =>
                let low = next(10)
                let high = low + next(10)
                let items: Array<Any> = [low, high]
                let _ = pattern.constrain("amount", Operator.Between, items)
            case 5 =>
                let items: Array<Any> = [next(20), next(20)]
                let _ = pattern.constrain("amount", Operator.In, items)
            case 6 => let _ = pattern.constrain("code", Operator.IsNull, 0)
            case 7 => let _ = pattern.constrain("code", Operator.Contains, if (next(2) == 0) { "A" } else { "B" })
            case _ => let _ = pattern.constrain("code", Operator.NotNull, 0)
        }
    }
}

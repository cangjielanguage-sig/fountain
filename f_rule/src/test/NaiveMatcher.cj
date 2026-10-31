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

import std.collection.{ArrayList, HashMap}
import fountain::f_rule.RuleRuntime
import fountain::f_rule.condition.{JitExpression, JoinConstraint, Pattern}
import fountain::f_rule.agenda.Bindings
import fountain::f_rule.fact.{Fact, IdentifiedFact}
import fountain::f_rule.rule.{Rule, RuleSet}

/**
 * 朴素匹配器产出的激活（`doc/09-testing.md` §4.1）。
 *
 * 只作为差分基准：不持有令牌与网络引用，`bindings` 直接指向事实实例。
 */
public class NaiveActivation {
    public let rule: Rule
    public let bindings: Bindings

    public init(rule: Rule, bindings: Bindings) {
        this.rule = rule
        this.bindings = bindings
    }

    public prop ruleId: String {
        get() {
            rule.id
        }
    }

    public prop factSpace: String {
        get() {
            rule.factSpace
        }
    }

    public prop specificity: Int64 {
        get() {
            var total = Int64(rule.patterns.size)
            for (pattern in rule.patterns) {
                total += Int64(pattern.constraints.size)
            }
            total
        }
    }

    /** 稳定排序键：规则 id + 绑定的事实句柄无法取得，退化为绑定名的取值字符串。 */
    public func sortKey(): String {
        var out = "${factSpace}|${ruleId}|"
        let names = bindings.names()
        var i = 0
        while (i < names.size) {
            var j = i + 1
            while (j < names.size) {
                if (names[j] < names[i]) {
                    let tmp = names[i]
                    names[i] = names[j]
                    names[j] = tmp
                }
                j += 1
            }
            i += 1
        }
        for (name in names) {
            out = out + "${name}="
            match (bindings.resolve(name)) {
                case Some(fact) =>
                    match (fact as IdentifiedFact) {
                        case Some(identified) => out = out + "${identified.identity}"
                        case None => out = out + "?"
                    }
                case None => out = out + "?"
            }
            out = out + ";"
        }
        out
    }
}

/**
 * 朴素顺序匹配器：嵌套循环 + 逐条 join 判定（`doc/09-testing.md` §4.1）。
 *
 * 语义最直白，作为 M2 Rete 的差分基准。方法名用 [matches] 而不是文档的 `match`
 * （后者是仓颉关键字）。
 */
public class NaiveMatcher {
    private let rules: Array<Rule>
    private let scripts: HashMap<String, Array<JitExpression>>

    public init(ruleSet: RuleSet) {
        this.rules = ruleSet.rules
        this.scripts = HashMap<String, Array<JitExpression>>()
        let compiler = RuleRuntime.compiler()
        for (rule in ruleSet.rules) {
            if (rule.scripts.size == 0) {
                continue
            }
            let compiled = ArrayList<JitExpression>()
            for (source in rule.scripts) {
                compiled.add(JitExpression.of(source, compiler))
            }
            scripts[rule.id] = compiled.toArray()
        }
    }

    /** 按空间给出事实集合，返回全部激活。 */
    public func matches(factsBySpace: HashMap<String, Array<Fact>>): Array<NaiveActivation> {
        let out = ArrayList<NaiveActivation>()
        for (rule in rules) {
            let facts = match (factsBySpace.get(rule.factSpace)) {
                case Some(found) => found
                case None => Array<Fact>()
            }
            let candidates = ArrayList<Array<Fact>>()
            for (pattern in rule.patterns) {
                candidates.add(filter(pattern, facts))
            }
            let ruleScripts = match (scripts.get(rule.id)) {
                case Some(found) => found
                case None => Array<JitExpression>()
            }
            let walker = MatchWalker(rule, candidates.toArray(), ruleScripts, out)
            walker.walk(0)
        }
        out.toArray()
    }

    /** 单空间便捷入口。 */
    public func matches(space: String, facts: Array<Fact>): Array<NaiveActivation> {
        let map = HashMap<String, Array<Fact>>()
        map[space] = facts
        matches(map)
    }

    private func filter(pattern: Pattern, facts: Array<Fact>): Array<Fact> {
        let out = ArrayList<Fact>()
        for (fact in facts) {
            if (fact.typeTag == pattern.typeTag && pattern.matches(fact)) {
                out.add(fact)
            }
        }
        out.toArray()
    }
}

/** 递归组合器；独立成类是为了让可变状态显式化（闭包不能捕获可变变量）。 */
class MatchWalker {
    private let rule: Rule
    private let candidates: Array<Array<Fact>>
    private let scripts: Array<JitExpression>
    private let out: ArrayList<NaiveActivation>
    private let bindings: HashMap<String, Fact>

    MatchWalker(rule: Rule, candidates: Array<Array<Fact>>, scripts: Array<JitExpression>,
        out: ArrayList<NaiveActivation>) {
        this.rule = rule
        this.candidates = candidates
        this.scripts = scripts
        this.out = out
        this.bindings = HashMap<String, Fact>()
    }

    func walk(index: Int64): Unit {
        if (index >= Int64(candidates.size)) {
            emit()
            return
        }
        let pattern = rule.patterns[index]
        for (fact in candidates[index]) {
            bindings[pattern.binding] = fact
            walk(index + 1)
        }
        bindings.remove(pattern.binding)
    }

    private func emit(): Unit {
        for (join in rule.joins) {
            if (!join.eval(bindings).isTrue()) {
                return
            }
        }
        for (script in scripts) {
            if (!script.eval(bindings)) {
                return
            }
        }
        out.add(NaiveActivation(rule, Bindings.ofFacts(copyOf(bindings))))
    }

    private func copyOf(source: HashMap<String, Fact>): HashMap<String, Fact> {
        let copy = HashMap<String, Fact>()
        for ((key, value) in source) {
            copy[key] = value
        }
        copy
    }
}

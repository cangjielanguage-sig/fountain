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
package fountain::f_rule.rete

import std.collection.{ArrayList, HashSet}
import fountain::f_rule.condition.{Constraint, JoinConstraint, Operand, Pattern}
import fountain::f_rule.fact.{Fact, ValueKey}
import fountain::f_rule.rule.Rule

/**
 * 网络构建器（`doc/04-rete-network.md` §4、§6）。
 *
 * 职责：
 * 1. 把每个模式的约束**排序**成规范顺序，保证相同集合产生相同路径签名；
 * 2. alpha 节点按路径共享，形成树（不同路径末约束相同也各建一个，memory 语义不同）；
 * 3. beta 节点按 `(左路径, 右 alpha, join 集合)` 共享；
 * 4. 每个规则一个终端。
 *
 * 构建完成后由 `ReteNetwork` 冻结，运行期不再增加节点。
 */
public class NetworkBuilder {
    private init() {}

    public static func build(network: ReteNetwork, rules: Array<Rule>): Unit {
        for (rule in rules) {
            if (rule.factSpace != network.space) {
                continue
            }
            attach(network, rule)
        }
    }

    private static func attach(network: ReteNetwork, rule: Rule): Unit {
        let endpoints = ArrayList<AlphaNode>()
        for (pattern in rule.patterns) {
            endpoints.add(alphaChain(network, pattern, rule.id))
        }

        var current: ?BetaNode = None
        var index = 1
        while (index < rule.patterns.size) {
            let previous = current
            let leftSource = match (previous) {
                case Some(beta) => BetaLeft.FromBeta(beta.id)
                case None => BetaLeft.FromAlpha(endpoints[0].id)
            }
            let leftBinding = rule.patterns[index - 1].binding
            let joins = joinsAt(rule, index)
            let beta = network.betaNodeFor(leftSource, leftBinding, endpoints[index].id,
                joins, rule.patterns[index].binding, rule.id)
            endpoints[index].addRightConsumer(beta)
            match (previous) {
                case Some(outgoing) => outgoing.addConsumer(beta)
                case None => endpoints[0].addLeftConsumer(beta, rule.patterns[0].binding)
            }
            current = Some(beta)
            index += 1
        }

        let terminal = network.newTerminal(rule)
        match (current) {
            case Some(beta) => beta.addConsumer(terminal)
            case None => endpoints[0].addLeftConsumer(terminal, rule.patterns[0].binding)
        }
    }

    /** 单个模式的 alpha 链：类型过滤节点或逐约束路径。 */
    private static func alphaChain(network: ReteNetwork, pattern: Pattern,
        ruleId: String): AlphaNode {
        let constraints = sortedConstraints(pattern.constraints)
        if (constraints.size == 0) {
            let node = network.alphaNodeFor(AlphaSignature.typeOnly(pattern.typeTag),
                { _: Fact => true })
            node.addRule(ruleId)
            network.rootNode().addHead(node)
            return node
        }
        var parent: ?AlphaNode = None
        for (constraint in constraints) {
            let parentKey = match (parent) {
                case Some(existing) => existing.signature.key()
                case None => ""
            }
            let signature = AlphaSignature.fromConstraint(pattern.typeTag, constraint,
                parentKey: parentKey)
            let node = network.alphaNodeFor(signature, alphaTest(constraint))
            node.addRule(ruleId)
            match (parent) {
                case Some(existing) => existing.addChild(node)
                case None => network.rootNode().addHead(node)
            }
            parent = Some(node)
        }
        parent.getOrThrow()
    }

    /**
     * 约束测试闭包。
     *
     * 必须通过函数参数捕获：直接闭包捕获循环变量会让整条链共用最后一个约束，
     * 表现为"少约束也命中"的假阳性。
     */
    private static func alphaTest(constraint: Constraint): (Fact) -> Bool {
        { fact: Fact => constraint.eval(fact).isTrue() }
    }

    /** 第 `index` 个模式参与的连接约束：最大绑定下标恰为 `index` 的那些。 */
    private static func joinsAt(rule: Rule, index: Int64): Array<JoinConstraint> {
        let current = rule.patterns[index].binding
        let previous = HashSet<String>()
        var i = 0
        while (i < index) {
            previous.add(rule.patterns[i].binding)
            i += 1
        }
        let out = ArrayList<JoinConstraint>()
        for (join in rule.joins) {
            let touchesCurrent = join.leftBinding == current || join.rightBinding == current
            if (!touchesCurrent) {
                continue
            }
            let otherIsPrevious = previous.contains(join.leftBinding) ||
                previous.contains(join.rightBinding)
            if (otherIsPrevious) {
                out.add(join)
            }
        }
        sortJoins(out)
        out.toArray()
    }

    /** 约束规范排序：算子 → 字段 → 右操作数 → 否定标志。 */
    static func sortedConstraints(constraints: Array<Constraint>): Array<Constraint> {
        let items = ArrayList<Constraint>()
        for (constraint in constraints) {
            items.add(constraint)
        }
        let keys = ArrayList<String>()
        for (constraint in items) {
            keys.add(constraintKey(constraint))
        }
        var i = 1
        while (i < items.size) {
            let current = items[i]
            let currentKey = keys[i]
            var j = i - 1
            while (j >= 0 && keys[j] > currentKey) {
                items[j + 1] = items[j]
                keys[j + 1] = keys[j]
                j -= 1
            }
            items[j + 1] = current
            keys[j + 1] = currentKey
            i += 1
        }
        items.toArray()
    }

    private static func sortJoins(joins: ArrayList<JoinConstraint>): Unit {
        let keys = ArrayList<String>()
        for (join in joins) {
            keys.add(JoinSignature.joinKey(join))
        }
        var i = 1
        while (i < joins.size) {
            let current = joins[i]
            let currentKey = keys[i]
            var j = i - 1
            while (j >= 0 && keys[j] > currentKey) {
                joins[j + 1] = joins[j]
                keys[j + 1] = keys[j]
                j -= 1
            }
            joins[j + 1] = current
            keys[j + 1] = currentKey
            i += 1
        }
    }

    private static func constraintKey(constraint: Constraint): String {
        let right = match (constraint.right) {
            case Operand.Const(raw) => "c:" + NetworkBuilder.valueKey(raw)
            case Operand.Field(name) => "f:" + name
            case Operand.Bind(binding, field) => "b:${binding}.${field}"
        }
        "${constraint.field}\u{0001}${constraint.op}\u{0001}${right}\u{0001}${constraint.negated}"
    }

    private static func valueKey(raw: Any): String {
        try {
            ValueKey.of(raw).encode()
        } catch (e: Exception) {
            ""
        }
    }
}

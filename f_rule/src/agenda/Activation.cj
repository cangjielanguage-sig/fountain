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
package fountain::f_rule.agenda

import std.collection.ArrayList
import fountain::f_rule.fact.{Fact, IdentifiedFact}
import fountain::f_rule.rule.Bindings

/**
 * 议程激活（`doc/05-agenda-conflict-resolution.md` §2）。
 *
 * 由终端节点产出：`factSpace + ruleId + bindings` 唯一确定一个激活。
 * `key` 在构造时一次性算出，判等与哈希都只依赖它，避免每次比较都重算绑定表。
 *
 * `sortKey()` 与测试基准 `NaiveActivation.sortKey()` 保持同一格式，
 * 差分测试依赖这一点逐条比对两侧激活集合。
 */
public class Activation <: Hashable & Equatable<Activation> & ToString {
    public let factSpace: String
    public let ruleId: String
    public let bindings: Bindings
    public let specificity: Int64
    private let key_: String

    public init(factSpace: String, ruleId: String, bindings: Bindings, specificity: Int64) {
        this.factSpace = factSpace
        this.ruleId = ruleId
        this.bindings = bindings
        this.specificity = specificity
        this.key_ = Activation.sortKeyOf(factSpace, ruleId, bindings)
    }

    /** 稳定排序键，同时也是判等键。 */
    public func sortKey(): String {
        key_
    }

    public operator func ==(other: Activation): Bool {
        this.key_ == other.key_
    }

    public operator func !=(other: Activation): Bool {
        !(this == other)
    }

    public func hashCode(): Int64 {
        key_.hashCode()
    }

    public func toString(): String {
        "Activation(${key_})"
    }

    private static func sortKeyOf(factSpace: String, ruleId: String, bindings: Bindings): String {
        let names = sortedNames(bindings.bindings())
        var out = "${factSpace}|${ruleId}|"
        for (name in names) {
            out = out + "${name}="
            match (bindings.get(name)) {
                case Some(fact) => out = out + Activation.factKey(fact)
                case None => out = out + "?"
            }
            out = out + ";"
        }
        out
    }

    /** 与 `NaiveActivation.sortKey` 一致：优先用事实实例身份。 */
    private static func factKey(fact: Fact): String {
        match (fact as IdentifiedFact) {
            case Some(identified) => "${identified.identity}"
            case None => "?"
        }
    }

    private static func sortedNames(names: Array<String>): Array<String> {
        let copy = ArrayList<String>()
        for (name in names) {
            copy.add(name)
        }
        var i = 1
        while (i < copy.size) {
            let current = copy[i]
            var j = i - 1
            while (j >= 0 && copy[j] > current) {
                copy[j + 1] = copy[j]
                j -= 1
            }
            copy[j + 1] = current
            i += 1
        }
        copy.toArray()
    }
}

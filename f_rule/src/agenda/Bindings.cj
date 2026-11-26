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

import std.collection.{ArrayList, HashMap}
import fountain::f_rule.fact.{Fact, FactHandle, IdentifiedFact}

/**
 * 激活绑定表（`doc/05-agenda-conflict-resolution.md` §2）。
 *
 * 不可变视图：合并产生新实例，令牌与激活可以安全共享同一份绑定。
 * 每个绑定同时保留句柄与事实实例：
 *
 * - [get] 交出句柄，供动作上下文做 `retract` / 跨空间引用；
 * - [resolve] 交出事实实例，供条件求值与动作读取字段。
 *
 * Rete 路径两者都有；朴素匹配（差分基准）只构造事实，`get` 返回 `None`——它不参与
 * 动作执行，因此不需要句柄。
 */
public class Bindings {
    private let handles_: HashMap<String, FactHandle>
    private let facts_: HashMap<String, Fact>

    private init(handles: HashMap<String, FactHandle>, facts: HashMap<String, Fact>) {
        this.handles_ = handles
        this.facts_ = facts
    }

    public static func empty(): Bindings {
        Bindings(HashMap<String, FactHandle>(), HashMap<String, Fact>())
    }

    /** 句柄 + 事实的完整视图（Rete 路径）。 */
    public static func of(handles: HashMap<String, FactHandle>,
        facts: HashMap<String, Fact>): Bindings {
        Bindings(copyHandles(handles), copyFacts(facts))
    }

    /**
     * 接管两个映射的所有权（**不复制**）。
     *
     * 供高频路径使用：调用方必须是这两个映射的唯一持有者，交出后不得再修改。
     * 令牌展开时刚构造好的映射直接交给 `Bindings`，省掉一次全量复制。
     */
    public static func adopt(handles: HashMap<String, FactHandle>,
        facts: HashMap<String, Fact>): Bindings {
        Bindings(handles, facts)
    }

    /** 只有事实的视图（朴素匹配 / 手工测试）；[get] 永远返回 `None`。 */
    public static func ofFacts(facts: HashMap<String, Fact>): Bindings {
        Bindings(HashMap<String, FactHandle>(), copyFacts(facts))
    }

    /** 绑定名 → 事实句柄；没有句柄时返回 `None`。 */
    public func get(binding: String): ?FactHandle {
        handles_.get(binding)
    }

    /** 绑定名 → 事实实例。 */
    public func resolve(binding: String): ?Fact {
        facts_.get(binding)
    }

    /** 全部绑定名（字典序，保证遍历与指纹稳定）。 */
    public func names(): Array<String> {
        let names = ArrayList<String>()
        for ((name, _) in facts_) {
            names.add(name)
        }
        for ((name, _) in handles_) {
            if (!containsName(names, name)) {
                names.add(name)
            }
        }
        sortNames(names)
        names.toArray()
    }

    /** 绑定名 → 句柄的快照。 */
    public func toMap(): HashMap<String, FactHandle> {
        copyHandles(handles_)
    }

    /** 绑定名 → 事实实例的快照（连接约束与朴素匹配内部使用）。 */
    public func toFactMap(): HashMap<String, Fact> {
        copyFacts(facts_)
    }

    /** 合并一个绑定，返回新实例。 */
    public func merged(binding: String, handle: FactHandle, fact: Fact): Bindings {
        let handles = copyHandles(handles_)
        let facts = copyFacts(facts_)
        handles[binding] = handle
        facts[binding] = fact
        Bindings(handles, facts)
    }

    public func size(): Int64 {
        var total = facts_.size
        for ((name, _) in handles_) {
            if (!facts_.contains(name)) {
                total += 1
            }
        }
        total
    }

    public func isEmpty(): Bool {
        size() == 0
    }

    /**
     * 稳定指纹：排序后的 `name=identity;` 串。
     *
     * 激活相等性与差分测试都靠它，因此不能依赖 `HashMap` 的遍历顺序。
     * 事实实例有进程内身份（`IdentifiedFact`）时用身份，否则退化为句柄。
     */
    public func sortKey(): String {
        var out = ""
        for (name in names()) {
            out = out + "${name}="
            match (facts_.get(name)) {
                case Some(fact) =>
                    match (fact as IdentifiedFact) {
                        case Some(identified) => out = out + "${identified.identity}"
                        case None => out = out + Bindings.handleKey(handles_.get(name))
                    }
                case None => out = out + Bindings.handleKey(handles_.get(name))
            }
            out = out + ";"
        }
        out
    }

    private static func handleKey(handle: ?FactHandle): String {
        match (handle) {
            case Some(found) => "${found}"
            case None => "?"
        }
    }

    private static func containsName(names: ArrayList<String>, name: String): Bool {
        for (existing in names) {
            if (existing == name) {
                return true
            }
        }
        false
    }

    private static func sortNames(names: ArrayList<String>): Unit {
        var i = 1
        while (i < names.size) {
            let current = names[i]
            var j = i - 1
            while (j >= 0 && names[j] > current) {
                names[j + 1] = names[j]
                j -= 1
            }
            names[j + 1] = current
            i += 1
        }
    }

    private static func copyHandles(source: HashMap<String, FactHandle>): HashMap<String, FactHandle> {
        let copy = HashMap<String, FactHandle>()
        for ((key, value) in source) {
            copy[key] = value
        }
        copy
    }

    private static func copyFacts(source: HashMap<String, Fact>): HashMap<String, Fact> {
        let copy = HashMap<String, Fact>()
        for ((key, value) in source) {
            copy[key] = value
        }
        copy
    }
}

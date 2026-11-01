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
package fountain::f_rule.rule

import std.collection.{ArrayList, HashMap}

/**
 * 决策表动作：把 `then.*` 列的值写进输出槽（`doc/05-agenda-conflict-resolution.md` §7）。
 *
 * 不产生任何事实副作用，命中策略的聚合完全依赖输出槽。
 * 列值本身可以是字面量，也可以是绑定字段引用——引用解析由决策表编译器完成，
 * 这里只负责写入最终值。
 */
public class TableAction <: RuleAction {
    private let entries_: ArrayList<(String, Any)>

    public init(values: HashMap<String, Any>) {
        let entries = ArrayList<(String, Any)>()
        for ((name, value) in values) {
            entries.add((name, value))
        }
        this.entries_ = entries
    }

    public init(entries: Array<(String, Any)>) {
        let copy = ArrayList<(String, Any)>()
        for (entry in entries) {
            copy.add(entry)
        }
        this.entries_ = copy
    }

    public func execute(ctx: ActionContext): Unit {
        for ((name, value) in entries_) {
            ctx.set(name, value)
        }
    }

    /** 兼容旧调用点：动作对象自身就是 `RuleAction`。 */
    public func asRuleAction(): RuleAction {
        this
    }
}

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

import std.collection.HashMap
import fountain::f_rule.fact.{Fact, FactHandle}

/**
 * 动作上下文契约（`doc/05-agenda-conflict-resolution.md` §7）。
 *
 * 声明在 `rule` 包是分层需要：`Rule` 持有动作闭包，而 `agenda` 依赖 `rule`；
 * 若把接口放在 `agenda` 会形成包循环。M3 的 `SessionActionContext` 实现本接口，
 * 根包重导出后用户面仍是 `ActionContext`。
 */
public interface ActionContext {
    /** 当前激活所属事实库空间；动作默认只读写这个空间。 */
    prop factSpace: String
    func fact(binding: String): ?Fact
    func assert(fact: Fact): FactHandle
    func retract(handle: FactHandle): Unit
    func update(handle: FactHandle, fact: Fact): Unit
    func set(name: String, value: Any): Unit
    func get(name: String): ?Any
    func outputs(): HashMap<String, Any>
    /** 跨空间只读访问。 */
    func factIn(space: String, handle: FactHandle): ?Fact
    /** 把事实复制到另一个空间，返回目标空间的新句柄。 */
    func copyTo(space: String, fact: Fact): FactHandle
}

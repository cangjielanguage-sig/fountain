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

import fountain::f_rule.rule.{ActionContext, RuleAction}

/**
 * 宿主闭包动作（`doc/05-agenda-conflict-resolution.md` §7）。
 *
 * `Rule.then { ctx => ... }` 在 M2 已直接存成函数类型；本类提供显式对象形态，
 * 供需要跨模块传递动作（决策表、流程编排）的场景使用。
 */
public class ClosureAction {
    private let body: (ActionContext) -> Unit

    public init(body: (ActionContext) -> Unit) {
        this.body = body
    }

    public func execute(ctx: ActionContext): Unit {
        body(ctx)
    }

    /** 转成 `RuleBuilder.then` 接受的函数类型。 */
    public func asRuleAction(): RuleAction {
        let self = this
        { ctx: ActionContext => self.execute(ctx) }
    }
}

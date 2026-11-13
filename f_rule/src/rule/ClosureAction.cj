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

/**
 * 宿主闭包动作（`doc/05-agenda-conflict-resolution.md` §7）。
 *
 * `RuleBuilder.then { ctx => ... }` 的公开签名不变，内部统一包成 `RuleAction` 接口。
 */
public class ClosureAction <: RuleAction {
    private let body_: (ActionContext) -> Unit

    public init(body: (ActionContext) -> Unit) {
        this.body_ = body
    }

    public func execute(ctx: ActionContext): Unit {
        body_(ctx)
    }

    /** 兼容旧调用点：动作对象自身就是 `RuleAction`。 */
    public func asRuleAction(): RuleAction {
        this
    }
}

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
package fountain::f_rule.engine

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_rule.agenda.ClosureAction
import fountain::f_rule.condition.Pattern
import fountain::f_rule.exception.{RuleErrorCode, RuleException}
import fountain::f_rule.fact.DynamicFact
import fountain::f_rule.rule.{ActionContext, Rule, RuleAction, RuleSet, RuleSetBuilder}

func scriptActionRuleSet(source: String): RuleSet {
    let rule = Rule.builder("R1")
        .addPattern(Pattern.any("ActionOrder", "o"))
        .thenScript(source)
        .build()
    RuleSetBuilder("action")
        .version("v1")
        .registerDynamicType("ActionOrder", [])
        .rule(rule)
        .build()
}

func actionRuleSet(then: (ActionContext) -> Unit): RuleSet {
    let rule = Rule.builder("R1")
        .addPattern(Pattern.any("ActionOrder", "o"))
        .then(then)
        .build()
    RuleSetBuilder("action")
        .version("v1")
        .registerDynamicType("ActionOrder", [])
        .rule(rule)
        .build()
}

/**
 * `ScriptAction`（`doc/05-agenda-conflict-resolution.md` §7）。
 *
 * 动作由 `f_jit` 编译的规则体执行；编译失败在构建期抛 `SCRIPT_COMPILE`。
 * 现有 `then(action: (ActionContext) -> Unit)` 的公开签名保持不变。
 */
@Test
class ScriptAction_test {
    /** 完整 lambda 形态的脚本动作能写输出槽。 */
    @TestCase
    public func scriptActionWritesOutput(): Unit {
        let engine = RuleEngine(scriptActionRuleSet(
            "{ ctx: ActionContext => ctx.set(\"discount\", 0.85f64) }"))
        let session = engine.session("s1")
        let _ = session.assert(DynamicFact("ActionOrder"))

        let outputs = session.fire()
        @Expect(outputs.contains("discount"), true)
        let discount = match (outputs.get("discount")) {
            case Some(value) =>
                match (value as Float64) {
                    case Some(number) => number
                    case None => 0.0
                }
            case None => 0.0
        }
        @Assert(discount, 0.85)
    }

    /** 裸规则体自动包装成 `{ ctx: ActionContext => ... }`。 */
    @TestCase
    public func bareScriptBodyIsWrapped(): Unit {
        let engine = RuleEngine(scriptActionRuleSet("ctx.set(\"hit\", true)"))
        let session = engine.session("s1")
        let _ = session.assert(DynamicFact("ActionOrder"))

        @Expect(session.fire().contains("hit"), true)
    }

    /** 编译失败在构建期抛 `SCRIPT_COMPILE`，不留到运行期。 */
    @TestCase
    public func compileFailureThrowsScriptCompile(): Unit {
        var code = RuleErrorCode.CLOSED
        var caught = false
        try {
            let _ = scriptActionRuleSet("{ ctx: ActionContext => ctx.set( }")
        } catch (e: RuleException) {
            code = e.code
            caught = true
        }
        @Expect(caught, true)
        @Expect(code, RuleErrorCode.SCRIPT_COMPILE)
    }

    /** `RuleAction` 是接口：闭包动作对象可被显式执行。 */
    @TestCase
    public func closureActionImplementsRuleAction(): Unit {
        let action: RuleAction = ClosureAction({ ctx: ActionContext => ctx.set("closure", true) })
        let engine = RuleEngine(actionRuleSet({ ctx: ActionContext => action.execute(ctx) }))
        let session = engine.session("s1")
        let _ = session.assert(DynamicFact("ActionOrder"))

        @Expect(session.fire().contains("closure"), true)
    }
}

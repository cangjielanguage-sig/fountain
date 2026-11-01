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
import fountain::f_jit.*
import fountain::f_jit.macros.*
import fountain::f_rule.condition.{Operator, Pattern}
import fountain::f_rule.exception.RuleErrorCode
import fountain::f_rule.fact.{FactSchema, FieldType, TypedFact}
import fountain::f_rule.rule.{Rule, RuleSetBuilder}
import fountain::f_rule.runtime.RuleRuntime

/** 脚本条件测试宿主类：字段必须 public 才能被反射注册。 */
@JitBind
public class ScriptOrder {
    public var amount: Int64
    public var level: Int64

    public init(amount: Int64, level: Int64) {
        this.amount = amount
        this.level = level
    }
}

func scriptOrderSchema(): FactSchema<ScriptOrder> {
    FactSchema<ScriptOrder>("ScriptOrder")
        .field("amount", FieldType.Number) { o => o.amount }
        .field("level", FieldType.Number) { o => o.level }
}

/** 一条带脚本条件的规则：模式只约束金额，等级由脚本判定。 */
func scriptRuleSet(script: String): RuleSetBuilder {
    // 脚本走 JIT 时必须先注册宿主类，否则 f_jit 报「未注册的类名」。
    let compiler = Compiler()
    compiler.registerType<ScriptOrder>()
    RuleRuntime.initCompiler(compiler)
    let rule = Rule.builder("R1")
        .addPattern(Pattern("ScriptOrder", "o").constrain("amount", Operator.Gt, 200))
        .script(script)
        .then({ ctx => ctx.set("hit", true) })
        .build()
    RuleSetBuilder("script")
        .version("v1")
        .registerFact(scriptOrderSchema())
        .rule(rule)
}

/**
 * 终端节点的脚本条件求值。
 *
 * `Rule.scripts` 是规则的附加判定，必须在产生激活前求值；否则规则退化为
 * 「模式匹配即触发」，脚本被静默忽略。
 */
@Test
class ScriptCondition_test {
    /** 脚本判定为 false 时不产生激活。 */
    @TestCase
    public func scriptFalseProducesNoActivation(): Unit {
        let engine = RuleEngine(scriptRuleSet("{ o: ScriptOrder => o.level > 3 }").build())
        let session = engine.session("s1")
        let _ = session.assert(TypedFact(ScriptOrder(500, 1), scriptOrderSchema()))

        let outputs = session.fire()
        @Expect(outputs.contains("hit"), false)
    }

    /** 脚本判定为 true 时产生激活。 */
    @TestCase
    public func scriptTrueProducesActivation(): Unit {
        let engine = RuleEngine(scriptRuleSet("{ o: ScriptOrder => o.level > 3 }").build())
        let session = engine.session("s1")
        let _ = session.assert(TypedFact(ScriptOrder(500, 5), scriptOrderSchema()))

        let outputs = session.fire()
        @Expect(outputs.contains("hit"), true)
    }

    /** 脚本引用未声明的绑定名时，构建期拒绝。 */
    @TestCase
    public func scriptUndeclaredBindingRejectedAtBuild(): Unit {
        let builder = scriptRuleSet("{ x: ScriptOrder => x.level > 3 }")
        let ruleSet = builder.buildOrInvalid()
        @Expect(ruleSet.isValid(), false)
        match (builder.lastError()) {
            case Some(err) => @Expect(err.code, RuleErrorCode.SCRIPT_BINDING_MISSING)
            case None => @Fail("应当记录 SCRIPT_BINDING_MISSING")
        }
    }
}

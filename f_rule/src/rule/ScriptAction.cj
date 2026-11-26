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

import std.collection.ArrayList
import std.reflect.TypeInfo
import fountain::f_jit.{Compiler, JitBindSupport, JitFunction}
import fountain::f_jit.base.{CallContext, ClassDescriptor, JitBindings, LocalType,
    PredefinedFunction, PublicCtor, PublicField, PublicMethod}
import fountain::f_rule.exception.{RuleErrorCode, RuleException}
import fountain::f_rule.runtime.RuleRuntime

/**
 * 脚本动作（`doc/05-agenda-conflict-resolution.md` §7）。
 *
 * 规则体形如 `{ ctx: ActionContext => ... }`；裸语句会自动包成该形态。
 * 编译在构造期完成，失败抛 `RuleException(SCRIPT_COMPILE)`，不留到运行期。
 *
 * `ActionContext` 的脚本面是**手工注册**的：`set` 按实参静态类型注册为四个重载
 * （`Int64/Float64/Bool/String`），每个绑定使用独立函数名。f_jit 的 `@JitBind` 会把
 * `Any` 形参映射成 `HostObject`，导致 `ctx.set("x", 0.85)` 无法通过类型检查，因此这里
 * 不用宏展开，而是显式描述脚本可见的方法表。
 */
public class ScriptAction <: RuleAction {
    private let source_: String
    private let compiled_: JitFunction

    public init(source: String) {
        this(source, RuleRuntime.compiler())
    }

    public init(source: String, compiler: Compiler) {
        let prepared = ScriptAction.wrap(source)
        this.source_ = prepared
        try {
            ScriptAction.ensureContextRegistered(compiler)
            this.compiled_ = compiler.compile(prepared)
        } catch (e: Exception) {
            throw RuleException(
                RuleErrorCode.SCRIPT_COMPILE,
                "脚本动作编译失败: ${e.message}",
                e
            )
        }
    }

    public prop source: String {
        get() {
            source_
        }
    }

    public func execute(ctx: ActionContext): Unit {
        let args: Array<Any> = [ctx]
        let _ = compiled_.call<Unit>(args, CallContext())
    }

    /** 裸规则体自动包装；完整 lambda 原样使用。 */
    private static func wrap(source: String): String {
        let trimmed = source.trimAscii()
        if (trimmed.startsWith("{")) {
            return trimmed
        }
        "{ ctx: ActionContext => ${trimmed} }"
    }

    /**
     * 注册 `ActionContext` 的脚本可见方法表；同一编译器只注册一次。
     *
     * 首参固定为 `HOST_OBJECT`（接口实例），与 `PublicMethod` 的契约一致。
     */
    private static func ensureContextRegistered(compiler: Compiler): Unit {
        let owner = TypeInfo.of<ActionContext>().name
        // 接口实参在 f_jit 入口按 `is I` 校验；谓词只能由调用方用语言级 `is` 固化。
        JitBindSupport.enrollInterfaceOf<ActionContext>(
            JitBindings.empty(),
            { o: Object => o is ActionContext }
        )
        if (compiler.hasClass(owner)) {
            return
        }
        let methods = ArrayList<PublicMethod>()
        methods.add(ScriptAction.setMethod(owner, "i64", LocalType.I64))
        methods.add(ScriptAction.setMethod(owner, "f64", LocalType.F64))
        methods.add(ScriptAction.setMethod(owner, "dec", LocalType.DECIMAL))
        methods.add(ScriptAction.setMethod(owner, "bool", LocalType.BOOL))
        methods.add(ScriptAction.setMethod(owner, "str", LocalType.STRING))
        methods.add(PublicMethod(
            name: "factSpace",
            bind: PredefinedFunction(
                "${owner}.factSpace",
                [LocalType.HOST_OBJECT],
                LocalType.STRING,
                { args => ScriptAction.contextArg(args[0]).factSpace }
            )
        ))
        compiler.registerClass(ClassDescriptor(
            name: owner,
            fields: Array<PublicField>(),
            methods: methods.toArray(),
            ctors: Array<PublicCtor>(),
            isInterface: true
        ))
    }

    private static func setMethod(owner: String, suffix: String,
        valueType: UInt16): PublicMethod {
        PublicMethod(
            name: "set",
            bind: PredefinedFunction(
                "${owner}.set_${suffix}",
                [LocalType.HOST_OBJECT, LocalType.STRING, valueType],
                LocalType.UNIT,
                { args =>
                    ScriptAction.contextArg(args[0]).set(
                        ScriptAction.stringArg(args[1]), args[2])
                    0
                }
            )
        )
    }

    private static func contextArg(value: Any): ActionContext {
        match (value as ActionContext) {
            case Some(ctx) => ctx
            case None => throw RuleException(
                RuleErrorCode.SCRIPT_COMPILE,
                "脚本动作上下文类型不符"
            )
        }
    }

    private static func stringArg(value: Any): String {
        match (value as String) {
            case Some(text) => text
            case None => throw RuleException(
                RuleErrorCode.SCRIPT_COMPILE,
                "脚本动作的输出槽名必须是字符串"
            )
        }
    }
}

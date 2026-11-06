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
package fountain::f_rule.condition

import std.collection.{ArrayList, HashMap}
import std.time.DateTime
import fountain::f_jit.{Compiler, JitFunction}
import fountain::f_jit.base.CallContext
import fountain::f_log.LoggerFactory
import fountain::f_rule.exception.*
import fountain::f_rule.fact.{Fact, FactSpaceRegistry, HostFact}

/** 表达式求值模式（`doc/03-condition-expression.md` §7）。 */
public enum ExpressionMode <: ToString & Equatable<ExpressionMode> {
    | JitPreferred
    | Interpreted

    public func toString(): String {
        match (this) {
            case JitPreferred => "JitPreferred"
            case Interpreted => "Interpreted"
        }
    }

    public operator func ==(other: ExpressionMode): Bool {
        this.toString() == other.toString()
    }

    public operator func !=(other: ExpressionMode): Bool {
        !(this == other)
    }
}

/**
 * 脚本布尔条件（`doc/03-condition-expression.md` §6）。
 *
 * 两种构造：
 * - [of]：完整 lambda 字面量（形参带类型）；
 * - [ofExpression]：裸表达式 + `(绑定名, 宿主类名)` 列表，由本类拼成 lambda。
 *
 * **动态事实**（宿主类名为空串，或 `DynamicFact`）的 `get(): ?Any` 无法进 f_jit，
 * 因此整条条件走内置解释器并在构建期记一次 WARN——这是能力性降级，不是"编译失败回退"。
 *
 * 运行期求值失败（除零、越界、类型不符）一律返回 `false`（`Unknown`），不把异常
 * 穿透到事件循环；编译期错误仍抛 `SCRIPT_COMPILE`，不静默降级。
 */
public class JitExpression {
    private static let log = LoggerFactory.getLogger<JitExpression>()
    private static var warnings: Int64 = 0

    private let source_: String
    private let parameters_: Array<String>
    private let compiled_: ?JitFunction
    private let program_: ?InterpreterProgram

    private init(source: String, parameters: Array<String>, compiled: ?JitFunction,
        program: ?InterpreterProgram) {
        this.source_ = source
        this.parameters_ = parameters
        this.compiled_ = compiled
        this.program_ = program
    }

    /** 从完整 lambda 编译；`source` 不以 `{` 开头或编译失败抛 `SCRIPT_COMPILE`。 */
    public static func of(source: String, compiler: Compiler): JitExpression {
        let trimmed = source.trimAscii()
        if (!trimmed.startsWith("{")) {
            throw RuleException(
                RuleErrorCode.SCRIPT_COMPILE,
                "JitExpression.of 要求完整 lambda 字面量（以 { 开头）: ${source}"
            )
        }
        let parameters = parseLambdaParameters(trimmed)
        let body = lambdaBody(trimmed)
        let compiled = compileLambda(trimmed, compiler)
        JitExpression(trimmed, parameters, Some(compiled), None)
    }

    /**
     * 裸表达式按绑定类型包装后编译。
     *
     * @param bindings `(绑定名, 宿主类简单名)`；宿主类名为空串表示动态事实
     */
    public static func ofExpression(source: String, bindings: Array<(String, String)>,
        compiler: Compiler): JitExpression {
        let names = ArrayList<String>()
        var dynamic = false
        for ((name, hostType) in bindings) {
            names.add(name)
            if (hostType == "" || hostType == "DynamicFact") {
                dynamic = true
            }
        }
        if (dynamic) {
            warnInterpreter(source, "动态事实绑定")
            let program = InterpreterProgram.compile(source)
            return JitExpression(source, names.toArray(), None, Some(program))
        }
        let header = ArrayList<String>()
        for ((name, hostType) in bindings) {
            header.add("${name}: ${hostType}")
        }
        let lambda = "{ ${JitExpression.join(header.toArray(), ", ")} => ${source} }"
        let compiled = compileLambda(lambda, compiler)
        JitExpression(lambda, names.toArray(), Some(compiled), None)
    }

    /**
     * 规则脚本条件入口：按模式的宿主类型选择 JIT 或解释器。
     *
     * - 完整 lambda（以 `{` 开头）在非动态绑定下直接编译；动态绑定改走 [interpretedOf]；
     * - 裸表达式按模式绑定拼成 lambda（同 [ofExpression]）；
     * - 任一绑定是动态事实时整条条件走解释器，构建期记一次 WARN。
     */
    public static func forRule(source: String, patterns: Array<Pattern>,
        registry: FactSpaceRegistry, space: String, compiler: Compiler,
        mode: ExpressionMode, warn!: Bool = true): JitExpression {
        let bindings = JitExpression.ruleBindings(patterns, registry, space)
        let names = ArrayList<String>()
        var dynamic = false
        for ((name, hostType) in bindings) {
            names.add(name)
            if (hostType == "" || hostType == "DynamicFact") {
                dynamic = true
            }
        }
        let trimmed = source.trimAscii()
        if (trimmed.startsWith("{")) {
            if (dynamic || mode == ExpressionMode.Interpreted) {
                if (dynamic && warn) {
                    warnInterpreter(source, "动态事实绑定")
                }
                return interpretedOf(trimmed)
            }
            return of(trimmed, compiler)
        }
        if (dynamic || mode == ExpressionMode.Interpreted) {
            if (dynamic && warn) {
                warnInterpreter(source, "动态事实绑定")
            }
            return interpreted(source, names.toArray())
        }
        ofExpression(trimmed, bindings, compiler)
    }

    private static func ruleBindings(patterns: Array<Pattern>, registry: FactSpaceRegistry,
        space: String): Array<(String, String)> {
        let out = ArrayList<(String, String)>()
        let factSpace = match (registry.get(space)) {
            case Some(found) => found
            case None => return out.toArray()
        }
        for (pattern in patterns) {
            let hostType = match (factSpace.descriptor(pattern.typeTag)) {
                case Some(descriptor) => descriptor.hostSimpleName
                case None => ""
            }
            out.add((pattern.binding, hostType))
        }
        out.toArray()
    }

    /** 强制使用内置解释器（决策表 `expr` 列 / `ExpressionMode.Interpreted`）。 */
    public static func interpreted(source: String, parameters: Array<String>): JitExpression {
        let program = InterpreterProgram.compile(source)
        JitExpression(source, parameters, None, Some(program))
    }

    /**
     * 从完整 lambda 字面量构造解释器版本（`ExpressionMode.Interpreted`）。
     *
     * 形参名从 lambda 头部解析，lambda 体交给内置解释器；解释器只覆盖白名单子集，
     * 超出子集抛 `SCRIPT_COMPILE`——这是能力边界，不静默降级为 JIT。
     */
    public static func interpretedOf(source: String): JitExpression {
        let trimmed = source.trimAscii()
        if (!trimmed.startsWith("{")) {
            throw RuleException(
                RuleErrorCode.SCRIPT_COMPILE,
                "interpretedOf 要求完整 lambda 字面量（以 { 开头）: ${source}"
            )
        }
        let parameters = parseLambdaParameters(trimmed)
        let body = lambdaBody(trimmed)
        interpreted(body, parameters)
    }

    public prop parameters: Array<String> {
        get() {
            parameters_
        }
    }

    public prop source: String {
        get() {
            source_
        }
    }

    /**
     * 是否走 f_jit 编译路径。
     *
     * `false` 表示该条件由内置解释器求值（动态事实、强制 `Interpreted`，或在
     * f_jit 缺陷修复前被降级的一元 `!`）。用于排查性能与验证降级是否按预期发生。
     */
    public prop usesJit: Bool {
        get() {
            compiled_.isSome()
        }
    }

    /**
     * 求值。
     *
     * @param bindings 绑定名 → 事实；参数顺序按 lambda 形参，不依赖 `HashMap` 顺序
     */
    public func eval(bindings: HashMap<String, Fact>): Bool {
        evalDetailed(bindings).value
    }

    /**
     * 求值并保留失败分类（`doc/03-condition-expression.md` §6.2）。
     *
     * JIT 路径把截止时间交给 `f_jit` 的 `CallContext`；解释器路径在步进时检查同一
     * 截止时间。任何异常/超时都不上抛，由调用方按 `Unknown` 处理。
     */
    public func evalDetailed(bindings: HashMap<String, Fact>,
        timeout!: ?Duration = None): EvalOutcome {
        let deadline: ?DateTime = match (timeout) {
            case Some(limit) => Some(DateTime.now() + limit)
            case None => None
        }
        match (program_) {
            case Some(program) => return program.evalOutcome(bindings, deadline: deadline)
            case None => ()
        }
        match (compiled_) {
            case Some(compiled) =>
                let args = ArrayList<Any>()
                for (name in parameters_) {
                    let fact = match (bindings.get(name)) {
                        case Some(found) => found
                        case None => return EvalOutcome.evaluated(false)
                    }
                    match (fact as HostFact) {
                        case Some(host) => args.add(host.hostObject())
                        case None => return interpretFallback(bindings, deadline)
                    }
                }
                try {
                    EvalOutcome.evaluated(
                        compiled.call<Bool>(args.toArray(), CallContext(deadline: deadline)))
                } catch (e: Exception) {
                    if (JitExpression.deadlinePassed(deadline)) {
                        EvalOutcome.failed(EvalFailureKind.Timeout, e.message)
                    } else {
                        EvalOutcome.failed(EvalFailureKind.RuntimeFailure, e.message)
                    }
                }
            case None => EvalOutcome.evaluated(false)
        }
    }

    /** 构建期校验形参都能在模式绑定中找到，缺失抛 `SCRIPT_BINDING_MISSING`。 */
    public func requireBindings(available: Array<String>): Unit {
        for (name in parameters_) {
            if (!available.contains(name)) {
                throw RuleException(
                    RuleErrorCode.SCRIPT_BINDING_MISSING,
                    "脚本形参 ${name} 在模式绑定中不存在（可用: ${JitExpression.join(available, ", ")}）"
                )
            }
        }
    }

    /** 测试观测用：解释器降级路径发出 WARN 的次数。 */
    public static func interpretationWarningCount(): Int64 {
        warnings
    }

    private static func warnInterpreter(source: String, reason: String): Unit {
        warnings += 1
        log.warn("脚本条件降级为内置解释器（${reason}）: ${source}")
    }

    private static func compileLambda(source: String, compiler: Compiler): JitFunction {
        try {
            compiler.compile(source)
        } catch (e: Exception) {
            throw RuleException(
                RuleErrorCode.SCRIPT_COMPILE,
                "脚本条件编译失败: ${e.message}",
                e
            )
        }
    }

    /** 从 lambda 头部解析形参名；`{ o: Order, u: User => ... }` → `["o", "u"]`。 */
    private static func parseLambdaParameters(source: String): Array<String> {
        let arrow = JitExpression.indexOrMinusOne(source, "=>")
        if (arrow < 0) {
            throw RuleException(
                RuleErrorCode.SCRIPT_COMPILE,
                "lambda 缺少 =>: ${source}"
            )
        }
        let open = JitExpression.indexOrMinusOne(source, "{")
        if (open < 0 || open > arrow) {
            throw RuleException(
                RuleErrorCode.SCRIPT_COMPILE,
                "lambda 头部非法: ${source}"
            )
        }
        let header = source[open + 1..arrow].trimAscii()
        let names = ArrayList<String>()
        if (header != "") {
            for (part in header.split(",")) {
                let trimmed = part.trimAscii()
                if (trimmed == "") {
                    continue
                }
                let colon = JitExpression.indexOrMinusOne(trimmed, ":")
                if (colon < 0) {
                    throw RuleException(
                        RuleErrorCode.SCRIPT_COMPILE,
                        "lambda 形参缺少类型: ${trimmed}"
                    )
                }
                names.add(trimmed[0..colon].trimAscii())
            }
        }
        if (names.isEmpty()) {
            throw RuleException(
                RuleErrorCode.SCRIPT_COMPILE,
                "lambda 至少需要一个带类型的形参: ${source}"
            )
        }
        names.toArray()
    }

    /** 非 HostFact（例如动态事实）在 JIT 表达式里出现时的兜底：按 lambda 体编译解释器。 */
    private func interpretFallback(bindings: HashMap<String, Fact>,
        deadline: ?DateTime): EvalOutcome {
        let arrow = JitExpression.indexOrMinusOne(source_, "=>")
        if (arrow < 0) {
            return EvalOutcome.evaluated(false)
        }
        var body = source_[arrow + 2..].trimAscii()
        if (body.endsWith("}")) {
            body = body[0..Int64(body.size) - 1].trimAscii()
        }
        try {
            InterpreterProgram.compile(body).evalOutcome(bindings, deadline: deadline)
        } catch (e: Exception) {
            EvalOutcome.failed(EvalFailureKind.RuntimeFailure, e.message)
        }
    }

    private static func deadlinePassed(deadline: ?DateTime): Bool {
        match (deadline) {
            case Some(limit) => DateTime.now() >= limit
            case None => false
        }
    }

    /** 取 `=>` 之后的 lambda 体并去掉尾部 `}`。 */
    private static func lambdaBody(source: String): String {
        let arrow = indexOrMinusOne(source, "=>")
        if (arrow < 0) {
            return source
        }
        var body = source[arrow + 2..].trimAscii()
        if (body.endsWith("}")) {
            body = body[0..Int64(body.size) - 1].trimAscii()
        }
        body
    }

    private static func indexOrMinusOne(source: String, needle: String): Int64 {
        match (source.indexOf(needle)) {
            case Some(index) => index
            case None => -1
        }
    }

    private static func join(items: Array<String>, separator: String): String {
        var out = ""
        var first = true
        for (item in items) {
            if (first) {
                out = item
                first = false
            } else {
                out = out + separator + item
            }
        }
        out
    }
}

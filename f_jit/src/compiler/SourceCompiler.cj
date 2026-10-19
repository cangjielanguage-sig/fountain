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
package fountain::f_jit.compiler

import std.collection.ArrayList
import fountain::f_jit.base.DiagnosticsSink
import fountain::f_jit.base.LocalType
import fountain::f_jit.base.PublicCtor
import fountain::f_jit.base.Version
import fountain::f_util.Fnv128

/**
 * 入口形参的 HostClosure 声明签名（不落 `.fbc`，供桥 Marshal 验签）。
 *
 * `paramNames` / `retName` 是 14 位置的**具体类名**（非 14 位置为空串）。只带类别码不足以
 * 区分 `(User) -> R` 与 `(Order) -> R`，而签名注册表正是按「码 + 类名」查 id（GAP-04/05）。
 */
protected class HostClosureSigDecl {
    public let params: Array<UInt16>
    public let paramNames: Array<String>
    public let ret: UInt16
    public let retName: String

    public init(params: Array<UInt16>, paramNames: Array<String>, ret: UInt16, retName: String) {
        this.params = params
        this.paramNames = paramNames
        this.ret = ret
        this.retName = retName
    }
}

/**
 * 源编译产物 —— design-m1 §4.3.9。
 *
 * 值语义、不可变：`.fbc` 字节 + 函数数 + 入口函数号 + 源码指纹（缓存去重键，§8.1）。
 * `protected`：根包管线（`CompilePipeline.runSource`）消费，用户面不直接见。
 */
protected struct CompiledSourceUnit {
    public let raw: Array<UInt8>
    public let funcCount: UInt32
    public let entryFn: UInt32
    public let fingerprint: UInt64
    /** 本单元物化出的构造器 helper（slot 序；不进 `.fbc`，供桥/执行侧解析 user hid）。 */
    public let ctorHelpers: Array<PublicCtor>
    /** 闭包静态捕获描述符（不进 `.fbc`，m2 §14.8）。 */
    public let captures: Array<CaptureDescriptor>
    /** 入口形参的 14 声明类名（类身份外置，§16.1）。 */
    public let entryParamClasses: Array<?String>
    /** 入口形参的 HostClosure 声明签名（§4/§16.4）。 */
    public let entryParamSigs: Array<?HostClosureSigDecl>

    public init(raw: Array<UInt8>, funcCount: UInt32, entryFn: UInt32, fingerprint: UInt64,
        ctorHelpers!: Array<PublicCtor> = Array<PublicCtor>(),
        captures!: Array<CaptureDescriptor> = Array<CaptureDescriptor>(),
        entryParamClasses!: Array<?String> = Array<?String>(),
        entryParamSigs!: Array<?HostClosureSigDecl> = Array<?HostClosureSigDecl>()) {
        this.raw = raw
        this.funcCount = funcCount
        this.entryFn = entryFn
        this.fingerprint = fingerprint
        this.ctorHelpers = ctorHelpers
        this.captures = captures
        this.entryParamClasses = entryParamClasses
        this.entryParamSigs = entryParamSigs
    }
}

/**
 * 管线编排 —— design-m1 §4.3.8、plan-m1 S3.21–S3.22。
 *
 * `lex → parse → resolve → DA → lower → assemble → .fbc`，每次 `compile` 自建
 * `CompileSession`，实例本身无跨调用可变状态（并发去重由根包 `CompileCache` 承担）。
 *
 * **与设计稿的一处形态偏差（显式记录）**：设计稿构造参数含 `opts: CompileOptions`，
 * 但 `CompileOptions` 属根包（§7.3.2），而包依赖 DAG 禁止 `compiler → 根包`。
 * 本实现只注入编译器真正需要的两项（注册表快照 + 诊断 sink）；`jit` / `cpuFeatures`
 * 不影响源编译产物（只影响后端选择），由根包在管线外层持有。
 */
protected class SourceCompiler {
    private let registry: PredefinedSnapshot
    private let diagnostics: DiagnosticsSink
    /** 汇编目标主版本（M1 缺省；M2 由调用方显式传 `Version.M2_MAJOR`）。 */
    private let verMajor: UInt16
    /** 类注册表快照（M2：类型注解 / 成员访问 / 构造降低的静态知识）。 */
    private let classes: ClassRegistrySnapshot

    public init(registry: PredefinedSnapshot, diagnostics: DiagnosticsSink,
        verMajor!: UInt16 = Version.MAJOR,
        classes!: ClassRegistrySnapshot = ClassRegistrySnapshot.empty()) {
        this.registry = registry
        this.diagnostics = diagnostics
        this.verMajor = verMajor
        this.classes = classes
    }

    /** 全管线：源码 → `.fbc` 字节（编译期错误一律抛 `SourceCompileException`）。 */
    public func compile(source: String): CompiledSourceUnit {
        let src = Lexer.normalizeNewlines(source)
        let view = ClassRegistryView(this.classes)
        let lambda = Parser(src, registered: { n => view.isRegistered(n) }).parseLambda()
        let resolver = NameResolver(this.registry, src)
        // 明确赋值与空安全（§7 校验 10）；类型查询按注解不可得 → 用 NONE（PUSH_NULL 检查保守放行）
        let da = DefiniteAssignment(src, { _ => LocalType.NONE },
            isClassName: { n =>
                view.isRegistered(n) || SourceCompiler.jsonFamily(n) || this.registry.has(n)
            })
        let _ = da.analyze(lambda)
        let sess = CompileSession(src, this.registry, this.diagnostics,
            verMajor: this.verMajor)
        let lowerer = Lowerer(sess, resolver, view: view)
        let entryFn = lowerer.lowerTop(lambda)
        let raw = Assembler(sess).assemble()
        let h = Fnv128.fnv1a(src)
        // 128 位 → 64 位：取低 64 位（缓存键只需稳定、不要求抗碰撞到 128 位）
        let fp = h.left
        let classes0 = ArrayList<?String>()
        let sigs0 = ArrayList<?HostClosureSigDecl>()
        for (p in lambda.params) {
            match (p.typeAnn) {
                case TypeRef.HostObjectT(n) =>
                    classes0.add(Some(n))
                    sigs0.add(None)
                case TypeRef.HostClosureT(ps, pns, r, rn) =>
                    classes0.add(None)
                    sigs0.add(Some(HostClosureSigDecl(ps, pns, r, rn)))
                case _ =>
                    classes0.add(None)
                    sigs0.add(None)
            }
        }
        CompiledSourceUnit(raw, UInt32(sess.funcCount), entryFn, fp,
            ctorHelpers: sess.ctorHelperList(), captures: lowerer.captureDescriptors(),
            entryParamClasses: classes0.toArray(), entryParamSigs: sigs0.toArray())
    }

    /** JSON 谱系类名（m3 内建码 16–19；构造写法在降低期拒绝）。 */
    private static func jsonFamily(name: String): Bool {
        name == 'JsonValue' || name == 'JsonObject' || name == 'JsonArray' || name == 'JsonNull'
    }
}

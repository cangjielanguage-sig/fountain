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

import fountain::f_jit.base.DiagnosticsSink
import fountain::f_jit.base.LocalType
import fountain::f_util.Fnv128

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

    public init(raw: Array<UInt8>, funcCount: UInt32, entryFn: UInt32, fingerprint: UInt64) {
        this.raw = raw
        this.funcCount = funcCount
        this.entryFn = entryFn
        this.fingerprint = fingerprint
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

    public init(registry: PredefinedSnapshot, diagnostics: DiagnosticsSink) {
        this.registry = registry
        this.diagnostics = diagnostics
    }

    /** 全管线：源码 → `.fbc` 字节（编译期错误一律抛 `SourceCompileException`）。 */
    public func compile(source: String): CompiledSourceUnit {
        let src = Lexer.normalizeNewlines(source)
        let lambda = Parser(src).parseLambda()
        let resolver = NameResolver(this.registry, src)
        // 明确赋值与空安全（§7 校验 10）；类型查询按注解不可得 → 用 NONE（PUSH_NULL 检查保守放行）
        let da = DefiniteAssignment(src, { _ => LocalType.NONE })
        let _ = da.analyze(lambda)
        let sess = CompileSession(src, this.registry, this.diagnostics)
        let lowerer = Lowerer(sess, resolver)
        let entryFn = lowerer.lowerTop(lambda)
        let raw = Assembler(sess).assemble()
        let h = Fnv128.fnv1a(src)
        // 128 位 → 64 位：取低 64 位（缓存键只需稳定、不要求抗碰撞到 128 位）
        let fp = h.left
        CompiledSourceUnit(raw, UInt32(sess.funcCount), entryFn, fp)
    }
}

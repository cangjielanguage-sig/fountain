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

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_jit.base.DummyDiagnosticsSink
import fountain::f_jit.base.LocalType
import fountain::f_jit.base.Version
import fountain::f_jit.runtime.HandleTable
import fountain::f_jit.runtime.HelperId
import fountain::f_jit.runtime.HostCallback
import fountain::f_jit.runtime.JitContext
import fountain::f_jit.runtime.SignatureDescriptor
import fountain::f_jit.runtime.invokeHelper
import fountain::f_jit.test.TCase
import fountain::f_jit.test.diff.DiffCase
import fountain::f_jit.test.diff.DiffSession
import fountain::f_jit.test.diff.InterpRunner
import fountain::f_jit.test.diff.NativeRunner

/**
 * Q6.3 / Q6.6 的编译器侧验收：三引擎差分（T33）与 M1 产物零回归（T49）。
 *
 * 差分纪律：**同一份 `.fbc`、同一组入参**，`Interp` 与原生后端逐位对拍结果/错误码/site/报告。
 * 宿主闭包以 `tag=10` 句柄作为实参传入（参数槽声明 13），两个引擎看到同一句柄表条目。
 */
@Test
public class Q6Compiler_test {
    private static func rawOf(src: String): Array<UInt8> {
        let sc = SourceCompiler(PredefinedSnapshot.empty(), DummyDiagnosticsSink(),
            verMajor: Version.M2_MAJOR)
        sc.compile(src).raw
    }

    private static func pin(fn: Any, params: Array<UInt16>, ret: UInt16): Int64 {
        HandleTable.pin(HostCallback(fn, SignatureDescriptor(params, ret)))
    }

    private static func diff(id: String, src: String, args: Array<Any>): DiffSession {
        let session = DiffSession([InterpRunner(), NativeRunner()])
        session.assertTripleEqual(DiffCase(id, Q6Compiler_test.rawOf(src), args))
        session
    }

    /** T33：确定性宿主闭包 × 值型参数/返回，两引擎结果逐位一致。 */
    @TestCase
    public func t33HostCallValueIsTripleEqual(): Unit {
        HandleTable.resetForTest()
        let h = Q6Compiler_test.pin({ x: Int64 => x * 10 + 1 },
            [LocalType.I64], LocalType.I64)
        let session = Q6Compiler_test.diff('T33/host-call-value',
            '{ f: (Int64) -> Int64, n: Int64 => f(n) + 1 }', [h, 4])
        @Assert(session.ran() >= 2, true)
        @Assert(TCase.hit('T33/host-call-value', session.skipped() == 0 && session.ran() >= 2), true)
        HandleTable.resetForTest()
    }

    /** T33：引用型返回（String）同样逐位一致（分配型 helper 的窗口账目一致）。 */
    @TestCase
    public func t33HostCallReferenceIsTripleEqual(): Unit {
        HandleTable.resetForTest()
        let h = Q6Compiler_test.pin({ => 'ok-host' }, Array<UInt16>(), LocalType.STRING)
        let session = Q6Compiler_test.diff('T33/host-call-string',
            '{ f: () -> String => f() }', [h])
        @Assert(session.ran() >= 2, true)
        @Assert(TCase.hit('T33/host-call-string', session.skipped() == 0 && session.ran() >= 2), true)
        HandleTable.resetForTest()
    }

    /** T33 / T60：宿主异常在两个引擎上都是 21 且 site 相同（21 与 99 不混）。 */
    @TestCase
    public func t33HostExceptionIsTripleEqual(): Unit {
        HandleTable.resetForTest()
        let h = Q6Compiler_test.pin({ _: Int64 => throw Exception('diff-boom') },
            [LocalType.I64], LocalType.I64)
        let session = Q6Compiler_test.diff('T33/host-exception',
            '{ f: (Int64) -> Int64 => f(1) }', [h])
        @Assert(session.ran() >= 2, true)
        @Assert(TCase.hit('T33/host-exception', session.skipped() == 0 && session.ran() >= 2), true)
        HandleTable.resetForTest()
    }

    /** T33：含重入（宿主闭包内再走一次 H63，新 ctx）的组合逐位一致。 */
    @TestCase
    public func t33ReentrantHostCallIsTripleEqual(): Unit {
        HandleTable.resetForTest()
        let inner = Q6Compiler_test.pin({ x: Int64 => x + 10 },
            [LocalType.I64], LocalType.I64)
        let fn: () -> Int64 = { =>
            let c2 = JitContext.create(hwBase: HandleTable.windowBaseOf(), hwCap: 32,
                fnId: 9, dbgBase: 0)
            let r = invokeHelper(c2, Int64(HelperId.HOST_CALL_TRAMPOLINE), [inner, 1])
            let e = c2.errCode
            JitContext.free(c2)
            if (e == 0) { r } else { -e }
        }
        let h = Q6Compiler_test.pin(fn, Array<UInt16>(), LocalType.I64)
        let session = Q6Compiler_test.diff('T33/reentrant',
            '{ f: () -> Int64 => f() }', [h])
        @Assert(session.ran() >= 2, true)
        @Assert(TCase.hit('T33/reentrant', session.skipped() == 0 && session.ran() >= 2), true)
        HandleTable.resetForTest()
    }

    /** T49：M1 产物与既有语义零变化（差分包全维度对拍）。 */
    @TestCase
    public func t49M1DiffRegressionIsZeroChange(): Unit {
        HandleTable.resetForTest()
        let session = DiffSession([InterpRunner(), NativeRunner()])
        session.assertTripleEqual(DiffCase('T49/m1-const',
            Q6Compiler_test.m1Raw('{ => 1 + 1 }'), Array<Any>()))
        session.assertTripleEqual(DiffCase('T49/m1-capture',
            Q6Compiler_test.m1Raw('{ a: Int64 => let f = { b: Int64 => a + b }\n f(2) }'), [1]))
        session.assertTripleEqual(DiffCase('T49/m1-container',
            Q6Compiler_test.m1Raw('{ => let l = [1, 2]\n l[0] + l[1] }'), Array<Any>()))
        session.assertTripleEqual(DiffCase('T49/m1-error',
            Q6Compiler_test.m1Raw('{ a: Int64 => 10 / a }'), [0]))
        @Assert(session.skipped(), 0)
        @Assert(TCase.hit('T49/m1-diff-zero-change', session.ran() == 8), true)
        HandleTable.resetForTest()
    }

    /** M1 版本产物（`verMajor` 缺省 = 1）。 */
    private static func m1Raw(src: String): Array<UInt8> {
        SourceCompiler(PredefinedSnapshot.empty(), DummyDiagnosticsSink()).compile(src).raw
    }
}

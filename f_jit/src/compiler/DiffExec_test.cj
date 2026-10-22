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
import fountain::f_jit.test.diff.AArch64Runner
import fountain::f_jit.test.diff.DiffCase
import fountain::f_jit.test.diff.NativeRunner
import fountain::f_jit.test.diff.DiffSession
import fountain::f_jit.test.diff.InterpRunner

/**
 * S5.11 后端合规判据（§12.7）：同一单元、同一输入，`Interp × AArch64`
 * 的结果 / NaN 位模式 / errCode / site 四项逐位一致。
 *
 * 非 Linux-aarch64 环境下 AArch64Runner 记入「跳过」而非失败（证据由 CI 矩阵补齐）。
 */
@Test
public class DiffExec_test {
    @TestCase
    public func constantAdd(): Unit {
        DiffExec_test.check('T2/const-1+1', '{ => 1 + 1 }', Array<Any>())
    }

    @TestCase
    public func multiArgumentAdd(): Unit {
        DiffExec_test.check('T2/args-add', '{ a: Int64, b: Int64 => a + b }',
            [20, 22])
    }

    @TestCase
    public func branchSelect(): Unit {
        DiffExec_test.check('T2/if', '{ n: Int64 => if (n > 0) { 10 } else { 20 } }',
            [-1])
    }

    @TestCase
    public func f64Add(): Unit {
        DiffExec_test.check('T2/f64-add', '{ => 1.5f64 + 2.5f64 }', Array<Any>())
    }

    @TestCase
    public func nanBitPattern(): Unit {
        DiffExec_test.check('T2/nan', '{ => 0.0f64 / 0.0f64 }', Array<Any>())
    }

    private static func check(id: String, src: String, args: Array<Any>): Unit {
        // 差分基线是 IEEE 语义（T2/nan）：显式关闭严格浮点
        let cu = SourceCompiler(PredefinedSnapshot.empty(), DummyDiagnosticsSink(),
            strictFp: false).compile(src)
        let c = DiffCase(id, cu.raw, args)
        let session = DiffSession([InterpRunner(), NativeRunner()])
        session.assertTripleEqual(c)
        @Assert(session.ran() >= 1, true)
    }
}

/** S6.12：S3.22 金样四例（Interp × AArch64 结果/错误码/站点一致）。 */
@Test
public class GoldenDiff_test {
    private static const DOLLAR: String = '$'

    @TestCase
    public func goldenFactorial(): Unit {
        GoldenDiff_test.check('G/factorial',
            '{ n: Int64 => if (n <= 1) { 1 } else { n * recursive(n - 1) } }', [5])
    }

    @TestCase
    public func goldenContainerMutation(): Unit {
        GoldenDiff_test.check('G/mutation', '{ => let l = [1, 2]\n l[0] = 3\n l[0] }',
            Array<Any>())
    }

    @TestCase
    public func goldenEmptyMap(): Unit {
        GoldenDiff_test.check('G/empty-map',
            '{ => let m: Map<String, Int64> = {}\n m["k"] = 1\n m["k"] }', Array<Any>())
    }

    /** S3.22 第 4 例：插值 —— `TO_STR` + `STR_CAT` 左结合，跨引擎逐位一致。 */
    @TestCase
    public func goldenInterpolation(): Unit {
        GoldenDiff_test.check('G/interp', '{ x: Int64 => "n=${GoldenDiff_test.DOLLAR}{x}!" }',
            [7])
    }

    @TestCase
    public func errorDivisionByZero(): Unit {
        GoldenDiff_test.check('E/div0', '{ a: Int64 => a / (a - a) }', [1])
    }

    @TestCase
    public func errorListIndexOutOfBounds(): Unit {
        GoldenDiff_test.check('E/list-oob', '{ => let l = [1, 2]\n l[5] }', Array<Any>())
    }

    /** T6：三引擎一致 + 期望错误码逐条断言。 */
    @TestCase
    public func errorModZero(): Unit {
        GoldenDiff_test.checkCode('E/mod0', '{ a: Int64 => a % (a - a) }', [1], 2)
    }

    @TestCase
    public func errorI64Overflow(): Unit {
        GoldenDiff_test.checkCode('E/overflow', '{ a: Int64 => a * a }', [3037000500], 3)
    }

    @TestCase
    public func errorMapKeyMissing(): Unit {
        GoldenDiff_test.checkCode('E/key-missing',
            '{ => let m: Map<String, Int64> = {}\n m["k"] }', Array<Any>(), 5)
    }


    private static func checkCode(id: String, src: String, args: Array<Any>,
        expect: Int64): Unit {
        let cu = SourceCompiler(PredefinedSnapshot.empty(), DummyDiagnosticsSink()).compile(src)
        let session = DiffSession([InterpRunner(), NativeRunner()])
        session.assertTripleEqual(DiffCase(id, cu.raw, args))
        let base = InterpRunner().run(DiffCase(id, cu.raw, args))
        @Assert(base.errCode, expect)
    }

    private static func check(id: String, src: String, args: Array<Any>): Unit {
        // 差分基线是 IEEE 语义（T2/nan）：显式关闭严格浮点
        let cu = SourceCompiler(PredefinedSnapshot.empty(), DummyDiagnosticsSink(),
            strictFp: false).compile(src)
        let session = DiffSession([InterpRunner(), NativeRunner()])
        session.assertTripleEqual(DiffCase(id, cu.raw, args))
    }
}

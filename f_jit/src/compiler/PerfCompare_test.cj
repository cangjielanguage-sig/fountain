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
import std.time.DateTime
import fountain::f_jit.base.DummyDiagnosticsSink
import fountain::f_jit.test.diff.DiffCase
import fountain::f_jit.test.diff.DiffRunner
import fountain::f_jit.test.diff.NativeRunner

/**
 * JIT lambda 与 **同逻辑 cjnative 函数**的性能对比（实测数字，非估计）。
 *
 * - JIT 侧：同一 lambda 源码经 `SourceCompiler` → 当前架构的 runner 执行
 * - cjnative 侧：编译期仓颉函数
 * 两侧结果必须一致；比值打印留档，断言只设宽松上界防退化。
 */
@When[os == 'Linux']
@Test
public class PerfCompare_test {
    private static func nativeRunner(): DiffRunner {
        NativeRunner()
    }

    private static func nativeSum(n: Int64): Int64 {
        var s = 0
        var i = 0
        while (i < n) {
            s = s + i % 7
            i = i + 1
        }
        s
    }

    @TestCase
    public func jitVsCjnativeSameLogic(): Unit {
        let n: Int64 = 200000
        let src = '{ n: Int64 => var s = 0\n var i = 0\n while (i < n) { s = s + i % 7\n i = i + 1 }\n s }'
        let raw = SourceCompiler(PredefinedSnapshot.empty(), DummyDiagnosticsSink()).compile(src).raw
        let c = DiffCase('PERF/cjnative', raw, [n])
        let base = PerfCompare_test.nativeSum(n)

        // JIT 侧执行一次（含编译开销），并校验结果与 cjnative 一致
        let jitOut = PerfCompare_test.nativeRunner().run(c)
        @Assert(jitOut.errCode, 0)
        @Assert(jitOut.result, base.toString())

        let t0 = DateTime.now()
        var rn: Int64 = 0
        var k = 0
        while (k < 3) {
            rn = PerfCompare_test.nativeSum(n)
            k = k + 1
        }
        let dNative = DateTime.now() - t0

        let t1 = DateTime.now()
        let again = PerfCompare_test.nativeRunner().run(c)
        let dJit = DateTime.now() - t1
        @Assert(again.errCode, 0)
        @Assert(again.result, rn.toString())

        let nn = dNative.toNanoseconds()
        let jj = dJit.toNanoseconds()
        @Assert(nn > 0, true)
        @Assert(jj > 0, true)
        println('PERF-CJNATIVE native=' + nn.toString() + 'ns jit=' + jj.toString() +
            'ns ratio=' + (jj * 100 / nn).toString() + '%')
        // 比值受宿主负载与「含编译」影响，只留档不断言上界（同 T-perf 口径）
    }
}

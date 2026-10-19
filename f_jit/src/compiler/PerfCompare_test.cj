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
import fountain::f_jit.backend.JitExecutor
import fountain::f_jit.base.DummyDiagnosticsSink
import fountain::f_jit.bytecode.FbcReader
import fountain::f_jit.runtime.Interp
import fountain::f_jit.runtime.JitContext

/**
 * S7.7 性能基线：**预编译后**的 JIT 稳态吞吐 vs 解释器 vs 同逻辑 cjnative 函数。
 *
 * 三者结构/副作用一致（同一个 while 循环、同一 `% 7` 累加）；JIT 编译/资产创建
 * 在计时外完成，避免把编译开销混进吞吐。数字打印留档，结果必须逐位一致。
 */
@When[os == 'Linux']
@Test
public class PerfCompare_test {
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
    public func jitVsInterpVsCjnative(): Unit {
        let n: Int64 = 200000
        let rounds: Int64 = 5
        let src = '{ n: Int64 => var s = 0\n var i = 0\n while (i < n) { s = s + i % 7\n i = i + 1 }\n s }'
        let cu = SourceCompiler(PredefinedSnapshot.empty(), DummyDiagnosticsSink()).compile(src)
        let unit = FbcReader.load(cu.raw)
        let base = PerfCompare_test.nativeSum(n)

        let ex = match (JitExecutor.create(unit, cu.entryFn)) {
            case Some(e) => e
            case None => @Fail('JIT 资产创建失败，无法测吞吐'); return
        }
        let ctx = JitContext.create(hwBase: 0, hwCap: 0, fnId: 0, dbgBase: 0)
        let interp = Interp(unit)
        try {
            // 预热 + 结果一致性
            let cj = ex.invoke(ctx, [n])
            ctx.errCode = 0
            ctx.site = -1
            let ci = interp.run(cu.entryFn, [n], ctx)
            @Assert(cj, base)
            @Assert(ci, base)

            let t0 = DateTime.now()
            var rn: Int64 = 0
            var k = 0
            while (k < rounds) {
                rn = PerfCompare_test.nativeSum(n)
                k = k + 1
            }
            let dNative = DateTime.now() - t0

            let t1 = DateTime.now()
            var rj: Int64 = 0
            k = 0
            while (k < rounds) {
                rj = ex.invoke(ctx, [n])
                k = k + 1
            }
            let dJit = DateTime.now() - t1

            let t2 = DateTime.now()
            var ri: Int64 = 0
            k = 0
            while (k < rounds) {
                ctx.errCode = 0
                ctx.site = -1
                ri = interp.run(cu.entryFn, [n], ctx)
                k = k + 1
            }
            let dInterp = DateTime.now() - t2

            @Assert(rj, rn)
            @Assert(ri, rn)
            let nn = dNative.toNanoseconds()
            let jj = dJit.toNanoseconds()
            let ii = dInterp.toNanoseconds()
            @Assert(nn > 0 && jj > 0 && ii > 0, true)
            println('PERF-M1 native=' + nn.toString() + 'ns jit=' + jj.toString() +
                'ns interp=' + ii.toString() + 'ns jit_vs_interp=' +
                (jj * 100 / ii).toString() + '% jit_vs_native=' +
                (jj * 100 / nn).toString() + '%')
        } finally {
            ex.release()
            JitContext.free(ctx)
        }
    }
}

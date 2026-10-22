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
package fountain::f_jit

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_jit.base.DummyDiagnosticsSink
import fountain::f_jit.base.ErrCode
import fountain::f_jit.base.JitException

/**
 * X3：`strictFp` 归位编译期。
 *
 * 旧实现里 `CallContext.strictFp` 写进 `ctx.flags` bit0 后无人读取——打开与关闭行为完全一样。
 * 现在它决定产物形态：`FDIV`（IEEE，÷0 得 ±Inf）或 `FDIV_CHK`（÷0 → 1）。
 */
@Test
public class StrictFp_test {

    private static const DIV_SRC: String = '{ x: Float64 => 1.0f64 / x }'

    /** 缺省即严格：不设任何选项，÷0 以 1 失败。 */
    @TestCase
    public func defaultIsStrict(): Unit {
        let f = Compiler(CompileOptions(DummyDiagnosticsSink()))
            .compile(StrictFp_test.DIV_SRC)
        var code = 0
        try {
            let _ = f.call<Float64>([0.0])
        } catch (e: JitException) {
            code = e.code
        }
        @Assert(code, ErrCode.DIV_ZERO)
    }

    /** 显式关闭严格：÷0 得 +Inf，不报错。 */
    @TestCase
    public func looseDivisionByZeroYieldsInf(): Unit {
        let opts = CompileOptions(DummyDiagnosticsSink())
        opts.strictFp = false
        let f = Compiler(opts).compile(StrictFp_test.DIV_SRC)
        let v = f.call<Float64>([0.0])
        @Assert(Int64(v.toBits()), Int64(0x7FF0000000000000u64))
    }

    /** 严格：÷0 以 1（`DIV_ZERO`）失败。 */
    @TestCase
    public func strictDivisionByZeroFails(): Unit {
        let opts = CompileOptions(DummyDiagnosticsSink())
        opts.strictFp = true
        let f = Compiler(opts).compile(StrictFp_test.DIV_SRC)
        var code = 0
        try {
            let _ = f.call<Float64>([0.0])
        } catch (e: JitException) {
            code = e.code
        }
        @Assert(code, ErrCode.DIV_ZERO)
    }

    /** 严格模式下非零除数照常计算（不是「一律拒绝」）。 */
    @TestCase
    public func strictStillComputesNormalDivision(): Unit {
        let opts = CompileOptions(DummyDiagnosticsSink())
        opts.strictFp = true
        let f = Compiler(opts).compile(StrictFp_test.DIV_SRC)
        @Assert(f.call<Float64>([2.0]).toBits(), 0.5f64.toBits())
    }

    /**
     * 缓存键含严格浮点标记：先以非严格编译同一源码（入缓存），再以严格编译。
     *
     * 若键不含该标记，第二次会命中第一次的产物，÷0 仍得 +Inf 而不是报错。
     */
    @TestCase
    public func strictFpIsPartOfCacheKey(): Unit {
        let looseOpts = CompileOptions(DummyDiagnosticsSink())
        looseOpts.strictFp = false
        let loose = Compiler(looseOpts)
        @Assert(Int64(loose.compile(StrictFp_test.DIV_SRC).call<Float64>([0.0]).toBits()),
            Int64(0x7FF0000000000000u64))

        let opts = CompileOptions(DummyDiagnosticsSink())
        opts.strictFp = true
        let strict = Compiler(opts).compile(StrictFp_test.DIV_SRC)
        var code = 0
        try {
            let _ = strict.call<Float64>([0.0])
        } catch (e: JitException) {
            code = e.code
        }
        @Assert(code, ErrCode.DIV_ZERO)
    }
}

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
import fountain::f_jit.base.{ErrCode, JitException, SourceCompileException}

/**
 * Int64 幂运算 `**`（仓颉 `Appendix/operator.md`：优先级 4、右结合；指数无符号 ⇒ 方言要求非负）
 * 与浮点/十进制科学计数法字面量。
 */
@Test
public class Pow_test {

    private static func compiler(): Compiler {
        Compiler()
    }

    private static func intOf(src: String, args: Array<Any>): Int64 {
        CompileCache.reset()
        Pow_test.compiler().compile(src).call<Int64>(args)
    }

    @TestCase
    public func powBasics(): Unit {
        @Assert(Pow_test.intOf('{ => 2 ** 10 }', []), 1024)
        @Assert(Pow_test.intOf('{ => 0 ** 0 }', []), 1)
        @Assert(Pow_test.intOf('{ => 0 ** 5 }', []), 0)
        @Assert(Pow_test.intOf('{ => (-2) ** 3 }', []), -8)
        @Assert(Pow_test.intOf('{ x: Int64 => x ** 0 }', [Int64(9)]), 1)
    }

    /** 右结合：`2 ** 3 ** 2` = `2 ** 9` = 512。 */
    @TestCase
    public func powIsRightAssociative(): Unit {
        @Assert(Pow_test.intOf('{ => 2 ** 3 ** 2 }', []), 512)
    }

    /** 优先级：高于 `*`（`2 * 3 ** 2` = 18）；一元负号更紧（`-2 ** 2` = 4）。 */
    @TestCase
    public func powPrecedence(): Unit {
        @Assert(Pow_test.intOf('{ => 2 * 3 ** 2 }', []), 18)
        @Assert(Pow_test.intOf('{ => -2 ** 2 }', []), 4)
    }

    /** 溢出 → 3（`ERR_OVERFLOW_I64`）。 */
    @TestCase
    public func powOverflowFails3(): Unit {
        CompileCache.reset()
        let f = Pow_test.compiler().compile('{ => 2 ** 63 }')
        var code: Int64 = 0
        try {
            let _ = f.call<Int64>([])
        } catch (e: JitException) {
            code = e.code
        }
        @Assert(code, ErrCode.OVERFLOW_I64)
    }

    /** 负指数 → 14（仓颉侧该情形类型上不可表达；方言以运行期码拒绝）。 */
    @TestCase
    public func powNegativeExponentFails14(): Unit {
        CompileCache.reset()
        let f = Pow_test.compiler().compile('{ x: Int64 => 2 ** x }')
        var code: Int64 = 0
        try {
            let _ = f.call<Int64>([Int64(-1)])
        } catch (e: JitException) {
            code = e.code
        }
        @Assert(code, ErrCode.ARG_MISMATCH)
    }

    /** 类型限制：非 `(Int64, Int64)` 编译期拒绝。 */
    @TestCase
    public func powRejectsNonInt64(): Unit {
        CompileCache.reset()
        var failed = false
        try {
            let _ = Pow_test.compiler().compile('{ => 1.5 ** 2 }')
        } catch (_: SourceCompileException) {
            failed = true
        }
        @Assert(failed, true)
    }
}

/** 科学计数法字面量：Decimal（无后缀）与 Float64（`f64` 后缀）。 */
@Test
public class NumberLitSci_test {

    private static func boolOf(src: String): Bool {
        CompileCache.reset()
        Compiler().compile(src).call<Bool>([])
    }

    @TestCase
    public func decimalSciNotation(): Unit {
        @Assert(NumberLitSci_test.boolOf('{ => 1.5e3 == 1500.0 }'), true)
        @Assert(NumberLitSci_test.boolOf('{ => 3e2 == 300.0 }'), true)
        @Assert(NumberLitSci_test.boolOf('{ => 1e-3 == 0.001 }'), true)
        @Assert(NumberLitSci_test.boolOf('{ => 2.4E-1 == 0.24 }'), true)
    }

    @TestCase
    public func floatSciNotation(): Unit {
        @Assert(NumberLitSci_test.boolOf('{ => 2e3f64 == 2000.0f64 }'), true)
        @Assert(NumberLitSci_test.boolOf('{ => .123e2f64 == 12.3f64 }'), true)
        @Assert(NumberLitSci_test.boolOf('{ => 1.5e3f64 == 1500.0f64 }'), true)
    }

    @TestCase
    public func leadingDotLiteral(): Unit {
        @Assert(NumberLitSci_test.boolOf('{ => .5 == 0.5 }'), true)
        @Assert(NumberLitSci_test.boolOf('{ => .5e2 == 50.0 }'), true)
    }
}

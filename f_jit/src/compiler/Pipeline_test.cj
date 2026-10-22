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
import fountain::f_jit.bytecode.FbcReader
import fountain::f_jit.bytecode.LoadedUnit
import fountain::f_jit.runtime.HandleTable
import fountain::f_jit.runtime.Interp
import fountain::f_jit.runtime.JitContext

/**
 * 源编译管线端到端（S3.10–S3.22 的验收面）：
 * `SourceCompiler` → `.fbc` → `FbcReader.load` → `Interp` 执行。
 *
 * 只经**产物**断言（不经 AST 匹配），因此不受「递归 AST 枚举在测试单元布局」影响。
 */
@Test
public class Pipeline_test {
    @TestCase
    public func compilesAndRunsConstant(): Unit {
        @Assert(Pipeline_test.runInt('{ => 1 }', []), 1)
    }

    @TestCase
    public func arithmeticPrecedenceAndUnary(): Unit {
        @Assert(Pipeline_test.runInt('{ => 1 + 2 * 3 }', []), 7)
        @Assert(Pipeline_test.runInt('{ => (1 + 2) * 3 }', []), 9)
        @Assert(Pipeline_test.runInt('{ => -5 + 2 }', []), -3)
        @Assert(Pipeline_test.runInt('{ => 7 % 3 }', []), 1)
    }

    @TestCase
    public func localsAndParameters(): Unit {
        @Assert(Pipeline_test.runInt('{ n: Int64 => let a = n * 2\n a + 1 }', [5]), 11)
    }

    @TestCase
    public func ifExpressionAndStatement(): Unit {
        @Assert(Pipeline_test.runInt('{ n: Int64 => if (n > 0) { n } else { 0 - n } }', [7]), 7)
        @Assert(Pipeline_test.runInt('{ n: Int64 => if (n > 0) { n } else { 0 - n } }', [-7]), 7)
        @Assert(Pipeline_test.runInt('{ n: Int64 => var x = 0\n if (n > 0) { x = 1 }\n x }', [1]), 1)
    }

    @TestCase
    public func whileLoopAndBreakContinue(): Unit {
        let src = '{ n: Int64 => var i = 0\n var s = 0\n while (i < n) { i = i + 1\n if (i == 3) { continue }\n if (i > 5) { break }\n s = s + i }\n s }'
        @Assert(Pipeline_test.runInt(src, [10]), 1 + 2 + 4 + 5)
    }

    @TestCase
    public func recursiveFactorial(): Unit {
        let src = '{ n: Int64 => if (n <= 1) { 1 } else { n * recursive(n - 1) } }'
        @Assert(Pipeline_test.runInt(src, [5]), 120)
    }

    @TestCase
    public func tailRecursiveUsesBackEdge(): Unit {
        // 尾位置 recursive：帧复用回边；1e6 次不爆栈
        let src = '{ n: Int64 => if (n <= 0) { 0 } else { recursive(n - 1) } }'
        @Assert(Pipeline_test.runInt(src, [100000]), 0)
    }

    @TestCase
    public func forInRangeAndList(): Unit {
        @Assert(Pipeline_test.runInt('{ n: Int64 => var s = 0\n for (i in 1..=n) { s = s + i }\n s }', [10]), 55)
        @Assert(Pipeline_test.runInt('{ => var s = 0\n for (x in [1, 2, 3]) { s = s + x }\n s }', []), 6)
    }

    @TestCase
    public func closureCapturesByValueAndCalls(): Unit {
        let src = '{ n: Int64 => let add = { y: Int64 => n + y }\n add(5) }'
        @Assert(Pipeline_test.runInt(src, [10]), 15)
    }

    @TestCase
    public func interpolationBuildsString(): Unit {
        // 仓颉自身会把 `${` 当插值起点：用拼接绕开
        let src = '{ x: Int64 => "n=' + Pipeline_test.DOLLAR + '{x}!" }'
        let unit = Pipeline_test.compile(src)
        let interp = Interp(unit)
        let ctx = JitContext.create(hwBase: 0, hwCap: 0, fnId: 0, dbgBase: 0)
        let r = interp.run(unit.header.entryFn, [7], ctx)
        let ok = ctx.errCode == 0
        JitContext.free(ctx)
        @Assert(ok, true)
        @Assert(HandleTable.fetchString(r), 'n=7!')
    }

    @TestCase
    public func containerLiteralsAndIndex(): Unit {
        @Assert(Pipeline_test.runInt('{ => let l = [10, 20, 30]\n l[1] }', []), 20)
        // 空字面值是**新分配的可变容器**（MAKE_MAP ⇒ MAP_PUT 合法）
        @Assert(Pipeline_test.runInt('{ => let m = {}\n m[1] = 11\n m[1] }', []), 11)
        @Assert(Pipeline_test.runInt('{ => let m = {1: 11, 2: 22}\n m[2] }', []), 22)
    }

    @TestCase
    public func unitTypesAndDirectoryAreConsistent(): Unit {
        let unit = Pipeline_test.compile('{ => 1 }')
        @Assert(Int64(unit.dir.size) >= 1, true)
        @Assert(unit.header.entryFn, unit.dir.at(0).fnId)
        @Assert(unit.types.size, Int64(unit.dir.size))
    }

    // ==================================================================

    private static const DOLLAR: String = '$'

    private static func compile(src: String): LoadedUnit {
        let sc = SourceCompiler(PredefinedSnapshot.empty(), DummyDiagnosticsSink())
        let unit = sc.compile(src)
        FbcReader.load(unit.raw)
    }

    private static func runInt(src: String, args: Array<Int64>): Int64 {
        let unit = Pipeline_test.compile(src)
        let interp = Interp(unit)
        let ctx = JitContext.create(hwBase: 0, hwCap: 0, fnId: 0, dbgBase: 0)
        let r = interp.run(unit.header.entryFn, args, ctx)
        JitContext.free(ctx)
        r
    }
}

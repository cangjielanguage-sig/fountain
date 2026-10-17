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
import std.time.*
import fountain::f_jit.base.DummyDiagnosticsSink
import fountain::f_jit.bytecode.FbcReader
import fountain::f_jit.bytecode.LoadedUnit
import fountain::f_jit.runtime.HandleTable
import fountain::f_jit.runtime.Interp
import fountain::f_jit.runtime.JitContext

/**
 * S3.18 的 DateTime / Duration 算术语义（§11.9）。
 *
 * 构造路径：源语言无 DateTime/Duration 字面量，因此由**宿主**构造值并 `HandleTable.pin`
 * 成句柄 ID，作为入口参数传入；返回值同样按句柄取回。这覆盖了
 * `DateTime.now()` / `DateTime + Duration` / `DateTime - DateTime` / `Duration * Int64` 等
 * 宿主侧构造方式在降低阶段的可观察行为。
 */
@Test
public class Temporal_test {

    /** `dt2 - dt1 → Duration`（DT_DIFF）。 */
    @TestCase
    public func datetimeDifference(): Unit {
        let a = DateTime.now()
        let b = a + Duration.second
        let r = Temporal_test.run('{ a: DateTime, b: DateTime => b - a }',
            [HandleTable.pin(a), HandleTable.pin(b)])
        @Assert(HandleTable.fetchDuration(r), Duration.second)
    }

    /** `dt + dur → DateTime`（DT_ADD）。 */
    @TestCase
    public func datetimePlusDuration(): Unit {
        let a = DateTime.now()
        let r = Temporal_test.run('{ a: DateTime, d: Duration => a + d }',
            [HandleTable.pin(a), HandleTable.pin(Duration.second)])
        @Assert(HandleTable.fetchDateTime(r), a + Duration.second)
    }

    /** `dt - dur → DateTime`（DT_SUB）。 */
    @TestCase
    public func datetimeMinusDuration(): Unit {
        let a = DateTime.now()
        let r = Temporal_test.run('{ a: DateTime, d: Duration => a - d }',
            [HandleTable.pin(a), HandleTable.pin(Duration.second)])
        @Assert(HandleTable.fetchDateTime(r), a - Duration.second)
    }

    /** `dur + dur` / `dur - dur`（DUR_ADD / DUR_SUB）。 */
    @TestCase
    public func durationAddSub(): Unit {
        let a = Duration.second * 2
        let b = Duration.second * 3
        let add = Temporal_test.run('{ a: Duration, b: Duration => a + b }',
            [HandleTable.pin(a), HandleTable.pin(b)])
        @Assert(HandleTable.fetchDuration(add), a + b)
        let sub = Temporal_test.run('{ a: Duration, b: Duration => a - b }',
            [HandleTable.pin(a), HandleTable.pin(b)])
        @Assert(HandleTable.fetchDuration(sub), a - b)
    }

    /** `dur * Int64` / `Int64 * dur` / `dur / Int64`（DUR_MUL / DUR_DIV）。 */
    @TestCase
    public func durationScale(): Unit {
        let d = Duration.second * 2
        let mul = Temporal_test.run('{ d: Duration, n: Int64 => d * n }', [HandleTable.pin(d), 3])
        @Assert(HandleTable.fetchDuration(mul), d * 3)
        let mulL = Temporal_test.run('{ d: Duration, n: Int64 => n * d }', [HandleTable.pin(d), 3])
        @Assert(HandleTable.fetchDuration(mulL), d * 3)
        let div = Temporal_test.run('{ d: Duration, n: Int64 => d / n }', [HandleTable.pin(d), 4])
        @Assert(HandleTable.fetchDuration(div), d / 4)
    }

    // ==================================================================

    private static func run(src: String, args: Array<Int64>): Int64 {
        let sc = SourceCompiler(PredefinedSnapshot.empty(), DummyDiagnosticsSink())
        let unit = FbcReader.load(sc.compile(src).raw)
        let interp = Interp(unit)
        let ctx = JitContext.create(hwBase: 0, hwCap: 0, fnId: 0, dbgBase: 0)
        let r = interp.run(unit.header.entryFn, args, ctx)
        let ok = ctx.errCode == 0
        JitContext.free(ctx)
        if (!ok) {
            @Fail('运行期失败: ${r}')
        }
        r
    }
}

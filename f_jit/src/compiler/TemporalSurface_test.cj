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
 * JIT lambda **源语言内**的 DateTime / Duration 构造（S3.18 扩展）：
 *
 * - `DateTime.now()` / `DateTime.parse(s)` / `DateTime.of(y,m,d[,h,mi,s[,ns]])`
 * - `Duration.<unit>`（nanosecond…day）与 `Duration.parse(s)`（f_data 同形串）
 *
 * 时间值仍以句柄承载；断言只比较 Duration 差值，避免依赖句柄 identity。
 */
@Test
public class TemporalSurface_test {

    @TestCase
    public func datetimeParseAndOf(): Unit {
        // RFC3339：+08:00 与 Z 表示同一瞬间
        let r = TemporalSurface_test.runHandle(
            '{ => DateTime.parse("2023-04-10T08:00:00+08:00") - DateTime.parse("2023-04-10T00:00:00Z") }')
        @Assert(HandleTable.fetchDuration(r), Duration.Zero)

        // of 的三参 / 六参形态与自身相减为 0（不依赖宿主时区）
        let a = TemporalSurface_test.runHandle('{ => DateTime.of(2023, 4, 10) - DateTime.of(2023, 4, 10) }')
        @Assert(HandleTable.fetchDuration(a), Duration.Zero)
        let b = TemporalSurface_test.runHandle(
            '{ => DateTime.of(2023, 4, 10, 8, 0, 0) - DateTime.of(2023, 4, 10, 8, 0, 0) }')
        @Assert(HandleTable.fetchDuration(b), Duration.Zero)
    }

    @TestCase
    public func datetimeNowIsCloseToHostNow(): Unit {
        let dt = HandleTable.fetchDateTime(TemporalSurface_test.runHandle('{ => DateTime.now() }'))
        var d = DateTime.now() - dt
        if (d < Duration.Zero) {
            d = Duration.Zero - d
        }
        @Assert(d < Duration.second * 5, true)
    }

    @TestCase
    public func durationUnits(): Unit {
        @Assert(TemporalSurface_test.durZero('{ => Duration.day - Duration.hour * 24 }'), true)
        @Assert(TemporalSurface_test.durZero('{ => Duration.hour - Duration.minute * 60 }'), true)
        @Assert(TemporalSurface_test.durZero('{ => Duration.minute - Duration.second * 60 }'), true)
        @Assert(TemporalSurface_test.durZero('{ => Duration.second - Duration.millisecond * 1000 }'), true)
        @Assert(TemporalSurface_test.durZero('{ => Duration.millisecond - Duration.microsecond * 1000 }'), true)
        @Assert(TemporalSurface_test.durZero('{ => Duration.microsecond - Duration.nanosecond * 1000 }'), true)
    }

    @TestCase
    public func durationParse(): Unit {
        @Assert(TemporalSurface_test.durZero(
            '{ => Duration.parse("1h2m3s") - (Duration.hour + Duration.minute * 2 + Duration.second * 3) }'),
            true)
        @Assert(TemporalSurface_test.durZero('{ => Duration.parse("-1m2s") - (Duration.Zero - Duration.minute - Duration.second * 2) }'),
            true)
    }

    @TestCase
    public func invalidParseReturns14(): Unit {
        @Assert(TemporalSurface_test.errCode('{ => DateTime.parse("not-a-date") }'), 14)
        @Assert(TemporalSurface_test.errCode('{ => Duration.parse("bad") }'), 14)
    }

    // ==================================================================

    private static func compile(src: String): LoadedUnit {
        let sc = SourceCompiler(PredefinedSnapshot.empty(), DummyDiagnosticsSink())
        FbcReader.load(sc.compile(src).raw)
    }

    private static func runHandle(src: String): Int64 {
        let unit = TemporalSurface_test.compile(src)
        let interp = Interp(unit)
        let ctx = JitContext.create(hwBase: 0, hwCap: 0, fnId: 0, dbgBase: 0)
        let r = interp.run(unit.header.entryFn, [], ctx)
        let ok = ctx.errCode == 0
        JitContext.free(ctx)
        if (!ok) {
            @Fail('运行期失败: ${r}')
        }
        r
    }

    private static func durZero(src: String): Bool {
        HandleTable.fetchDuration(TemporalSurface_test.runHandle(src)) == Duration.Zero
    }

    private static func errCode(src: String): Int64 {
        let unit = TemporalSurface_test.compile(src)
        let interp = Interp(unit)
        let ctx = JitContext.create(hwBase: 0, hwCap: 0, fnId: 0, dbgBase: 0)
        let _ = interp.run(unit.header.entryFn, [], ctx)
        let code = ctx.errCode
        JitContext.free(ctx)
        code
    }
}

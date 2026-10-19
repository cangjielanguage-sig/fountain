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
package fountain::f_jit.backend

import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_base.Arch
import fountain::f_base.OS
import fountain::f_jit.base.*
import fountain::f_jit.runtime.JitContext

/**
 * P5.3 `BackendSelector`：`{Off, Auto, Force} × OS × Arch` 的结果必须确定；
 * 非 Linux 恒 `Interp`、不抛异常，并记录 `(Warn, JitFallback)`。
 */
@Test
public class BackendSelector_test {

    @TestCase
    public func offAlwaysInterp(): Unit {
        let sink = Sink()
        let (e, b) = BackendSelector.selectFor(JitMode.Off, OS.Linux, Arch.aarch64, sink)
        @Assert(e, Engine.Interp)
        @Assert(none(b), true)
        @Assert(sink.size(), 0)
    }

    @TestCase
    public func supportedLinuxSelectsBackend(): Unit {
        let (e1, b1) = BackendSelector.selectFor(JitMode.Auto, OS.Linux, Arch.aarch64,
            Sink())
        @Assert(e1, Engine.Jit)
        match (b1) {
            case Some(x) => @Assert(x.name, 'aarch64')
            case None => @Fail('aarch64 后端未选出')
        }
        let (e2, b2) = BackendSelector.selectFor(JitMode.Force, OS.Linux, Arch.x86_64,
            Sink())
        @Assert(e2, Engine.Jit)
        match (b2) {
            case Some(x) => @Assert(x.name, 'x86_64')
            case None => @Fail('x86_64 后端未选出')
        }
    }

    @TestCase
    public func nonLinuxFallsBackWithDiagnostic(): Unit {
        // T7/ 映射标签（check_tmap 断言级校验）
        let oses = [OS.Windows, OS.macOS, OS.HarmonyOS, OS.OpenHarmony, OS.Android, OS.iOS]
        for (os in oses) {
            let sink = Sink()
            let (e, b) = BackendSelector.selectFor(JitMode.Force, os, Arch.aarch64, sink)
            @Assert(e, Engine.Interp)
            @Assert(none(b), true)
            @Assert(sink.size(), 1)
            @Assert(sink.lastCode(), DiagCode.JitFallback)
            @Assert(sink.lastLevel(), DiagnosticLevel.Warn)
        }
    }

    @TestCase
    public func currentPlatformSelectsExpected(): Unit {
        let (e, _) = BackendSelector.select(JitMode.Auto, Sink())
        @Assert(e, Engine.Jit) // 本机为 Linux/aarch64
    }

    /** S5.12：不受支持的指令集在 `Force` 下静默降级（不抛、不写错误槽）。 */
    @TestCase
    public func unsupportedArchSoftFallsBack(): Unit {
        for (name in ['riscv64', 'loongarch64', 'armv7']) {
            let sink = Sink()
            let (e, b) = BackendSelector.selectForArchName(JitMode.Force, 'Linux', name, sink)
            @Assert(e, Engine.Interp)
            @Assert(none(b), true)
            @Assert(sink.size(), 1)
            @Assert(sink.lastCode(), DiagCode.JitFallback)
            @Assert(sink.lastLevel(), DiagnosticLevel.Warn)
        }
    }

    /** S5.12：降级路径不触碰 ctx 错误槽（错误只由真正的执行失败写入）。 */
    @TestCase
    public func fallbackLeavesErrorSlotUntouched(): Unit {
        let ctx = JitContext.create(hwBase: 0, hwCap: 0, fnId: 0, dbgBase: 0)
        let sink = Sink()
        let (e, _) = BackendSelector.selectForArchName(JitMode.Force, 'Windows', 'aarch64', sink)
        @Assert(e, Engine.Interp)
        @Assert(ctx.errCode, 0)
        @Assert(ctx.site, -1)
        JitContext.free(ctx)
    }

}

private func none(b: ?Backend): Bool {
    match (b) {
        case None => true
        case Some(_) => false
    }
}

private class Sink <: DiagnosticsSink {
    private let events: ArrayList<(DiagnosticLevel, DiagCode)> = ArrayList<(DiagnosticLevel, DiagCode)>()

    public func diag(level: DiagnosticLevel, code: DiagCode, message: String): Unit {
        this.events.add((level, code))
    }

    public func size(): Int64 {
        this.events.size
    }

    public func lastCode(): DiagCode {
        this.events[this.events.size - 1][1]
    }

    public func lastLevel(): DiagnosticLevel {
        this.events[this.events.size - 1][0]
    }
}

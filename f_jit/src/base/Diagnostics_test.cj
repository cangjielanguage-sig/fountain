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
package fountain::f_jit.base

import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_base.BaseException

/**
 * S1.10 诊断接口的失败用例（先写红）。
 *
 * 权威 = design-m1 §2.3.7（D1 结案）：
 *
 * - 主签名 `diag(level, code, message)`（结构化入口，**稳定事件码**）+ 便捷重载
 *   `diag(level, message)`（默认实现：`code = Unspecified` 转发主签名）；
 * - `DiagnosticLevel` **只有 `Info` / `Warn` 两档**——错误一律走异常，走不到 diag；
 * - `DiagCode` 六个稳定事件码：`JitFallback` / `MmapFailed` / `RegistrationSkipped` /
 *   `PredefinedLimit` / `PlanFallback` / `Unspecified`；
 * - `DummyDiagnosticsSink` = **空实现**（`CompileOptions` 未显式传入时的默认值，兼测试用）；
 * - 契约 3：sink 抛出的异常由引擎吞掉（有在途异常 → `addSuppressed`；无在途 → 仅吞掉；
 *   `Error` 不捕；不重入 diag）。
 *
 * 「sink 异常不改语义（调用结果 / 错误码 / site 与不接 sink 时逐位一致）」的**引擎侧**证据在
 * S5.12 / S6.4 联测（plan-m1 S1.10 明写）；本文件先钉住 base 侧能定的部分：接口形态、
 * 六码、便捷重载转发、空实现，以及「sink 异常可被引擎吞掉 + 挂 suppressed」所依赖的
 * `BaseException.suppressed` 设施。
 */
@Test
public class Diagnostics_test {
    /** `DiagnosticLevel` 只有 `Info` / `Warn` 两档（错误一律走异常，D1 结案）。 */
    @TestCase
    public func diagnosticLevelHasOnlyInfoAndWarn(): Unit {
        let all = [DiagnosticLevel.Info, DiagnosticLevel.Warn]
        @Assert(all.size, 2)
        @Assert(all[0], DiagnosticLevel.Info)
        @Assert(all[1], DiagnosticLevel.Warn)
        @Assert(DiagnosticLevel.Info == DiagnosticLevel.Warn, false)
        for (level in all) {
            let text = match (level) {
                case DiagnosticLevel.Info => 'Info'
                case DiagnosticLevel.Warn => 'Warn'
            }
            @Assert(text.isEmpty(), false)
        }
    }

    /** `DiagCode` 六值逐值可断言、可 `match`（供 T7「存在 (Warn, JitFallback)」断言）。 */
    @TestCase
    public func diagCodeHasSixStableValues(): Unit {
        let all = [
            DiagCode.JitFallback, DiagCode.MmapFailed, DiagCode.RegistrationSkipped,
            DiagCode.PredefinedLimit, DiagCode.PlanFallback, DiagCode.Unspecified
        ]
        @Assert(all.size, 6)
        @Assert(all[0], DiagCode.JitFallback)
        @Assert(all[1], DiagCode.MmapFailed)
        @Assert(all[2], DiagCode.RegistrationSkipped)
        @Assert(all[3], DiagCode.PredefinedLimit)
        @Assert(all[4], DiagCode.PlanFallback)
        @Assert(all[5], DiagCode.Unspecified)
        for (code in all) {
            let text = match (code) {
                case DiagCode.JitFallback => 'JitFallback'
                case DiagCode.MmapFailed => 'MmapFailed'
                case DiagCode.RegistrationSkipped => 'RegistrationSkipped'
                case DiagCode.PredefinedLimit => 'PredefinedLimit'
                case DiagCode.PlanFallback => 'PlanFallback'
                case DiagCode.Unspecified => 'Unspecified'
            }
            @Assert(text.isEmpty(), false)
        }
    }

    /** 桩实现能同时记录 level + code + message（断言只看 level 与 code，不匹配 message 文本）。 */
    @TestCase
    public func stubRecordsLevelCodeAndMessage(): Unit {
        let sink = RecordingSink()
        sink.diag(DiagnosticLevel.Warn, DiagCode.JitFallback, '非 Linux 平台，降级为解释器')
        @Assert(sink.calls.size, 1)
        @Assert(sink.calls[0].level, DiagnosticLevel.Warn)
        @Assert(sink.calls[0].code, DiagCode.JitFallback)
        @Assert(sink.calls[0].message, '非 Linux 平台，降级为解释器')
        sink.diag(DiagnosticLevel.Info, DiagCode.MmapFailed, 'mmap 失败')
        @Assert(sink.calls.size, 2)
        @Assert(sink.calls[1].level, DiagnosticLevel.Info)
        @Assert(sink.calls[1].code, DiagCode.MmapFailed)
    }

    /** 便捷重载 `diag(level, message)` 以 `Unspecified` 码转发主签名（spec「便捷重载转发」）。 */
    @TestCase
    public func convenientOverloadForwardsAsUnspecified(): Unit {
        let sink = RecordingSink()
        sink.diag(DiagnosticLevel.Info, '未分类事件')
        @Assert(sink.calls.size, 1)
        @Assert(sink.calls[0].level, DiagnosticLevel.Info)
        @Assert(sink.calls[0].code, DiagCode.Unspecified)
        @Assert(sink.calls[0].message, '未分类事件')
    }

    /** 便捷重载可被实现方改写；改写后不再走 `Unspecified`（接口默认实现只是默认）。 */
    @TestCase
    public func convenientOverloadMayBeOverridden(): Unit {
        let sink = OverridingSink()
        sink.diag(DiagnosticLevel.Warn, '走改写路径')
        @Assert(sink.calls.size, 1)
        @Assert(sink.calls[0].code, DiagCode.PredefinedLimit)
        @Assert(sink.calls[0].level, DiagnosticLevel.Warn)
    }

    /** `DummyDiagnosticsSink` 两个入口皆空操作：不记录、不抛（默认 sink 的语义）。 */
    @TestCase
    public func dummySinkIsANoOp(): Unit {
        let sink = DummyDiagnosticsSink()
        sink.diag(DiagnosticLevel.Warn, DiagCode.JitFallback, '降级')
        sink.diag(DiagnosticLevel.Info, '未分类')
        @Assert(sink is DiagnosticsSink, true)
    }

    /** sink 抛异常：无在途异常 ⇒ 被引擎仅吞掉（不重抛）。 */
    @TestCase
    public func sinkExceptionIsSwallowedWhenNothingInFlight(): Unit {
        let sink = ThrowingSink()
        var swallowed = false
        try {
            sink.diag(DiagnosticLevel.Warn, DiagCode.JitFallback, '降级')
        } catch (e: Exception) {
            swallowed = true
        }
        @Assert(swallowed, true)
    }

    /** sink 抛异常：有在途异常 ⇒ 挂为 suppressed，**在途的那个继续传播**（码与 site 不变）。 */
    @TestCase
    public func sinkExceptionIsAttachedAsSuppressedWhenSomethingInFlight(): Unit {
        let sink = ThrowingSink()
        var code = 0
        var site = 0
        var suppressedCount = 0
        try {
            try {
                throw JitException(ErrCode.NOT_IMPL, -1, 0, None, '未实现特性')
            } catch (inflight: JitException) {
                try {
                    sink.diag(DiagnosticLevel.Warn, DiagCode.JitFallback, '降级')
                } catch (sinkEx: Exception) {
                    inflight.addSuppressed(sinkEx)
                }
                throw inflight
            }
        } catch (outer: JitException) {
            code = outer.code
            site = outer.site
            suppressedCount = outer.suppressed.size
        }
        @Assert(code, ErrCode.NOT_IMPL)
        @Assert(site, -1)
        @Assert(suppressedCount, 1)
    }
}

/** 诊断事件记录（测试桩用）：只承载断言所需的三元组。 */
private struct DiagRecord {
    let level: DiagnosticLevel
    let code: DiagCode
    let message: String

    init(level: DiagnosticLevel, code: DiagCode, message: String) {
        this.level = level
        this.code = code
        this.message = message
    }
}

/** 记录型桩：两个入口都落到同一条记录路径（主签名是唯一落点）。 */
private class RecordingSink <: DiagnosticsSink {
    public let calls = ArrayList<DiagRecord>()

    public func diag(level: DiagnosticLevel, code: DiagCode, message: String): Unit {
        calls.add(DiagRecord(level, code, message))
    }
}

/** 改写便捷重载的桩：证明默认实现可被覆盖，而不是硬编码行为。 */
private class OverridingSink <: DiagnosticsSink {
    public let calls = ArrayList<DiagRecord>()

    public func diag(level: DiagnosticLevel, code: DiagCode, message: String): Unit {
        calls.add(DiagRecord(level, code, message))
    }

    public func diag(level: DiagnosticLevel, message: String): Unit {
        calls.add(DiagRecord(level, DiagCode.PredefinedLimit, message))
    }
}

/** 抛异常的桩：模拟「诊断接收端自身出错」（写日志失败、格式化出错等）。 */
private class ThrowingSink <: DiagnosticsSink {
    public func diag(level: DiagnosticLevel, code: DiagCode, message: String): Unit {
        throw SinkFailure('diag 失败')
    }
}

/** sink 自身的失败（design §2.3.7：建议为 `BaseException` 子类，便于宿主统一 catch）。 */
private class SinkFailure <: BaseException {
    init(message: String) {
        super(message)
    }
}

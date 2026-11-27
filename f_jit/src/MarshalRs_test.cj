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
import fountain::f_jit.runtime.HandleTable

/** 注册类实参的护栏用类型。 */
public class MarshalProbeUser {
    public let name: String
    public init() {
        this.name = 'rs'
    }
}

/**
 * `CallMarshal` 携带 `rs` 与惰性容器的护栏（`optimize-marshal-rs`）。
 *
 * 覆盖：值型调用、String 去重、注册类透传（同一对象）、异常路径清理。
 */
@Test
public class MarshalRs_test {

    private static func compiler(): Compiler {
        Compiler(CompileOptions(DummyDiagnosticsSink()))
    }

    /** 值型调用连续 1000 次：结果稳定（惰性容器为空路径）。 */
    @TestCase
    public func valueCallsStayCorrect(): Unit {
        CompileCache.reset()
        let f = MarshalRs_test.compiler().compile('{ n: Int64 => n + 1 }')
        var i = 0
        while (i < 1000) {
            @Assert(f.call<Int64>([Int64(i)]), Int64(i) + 1)
            i = i + 1
        }
    }

    /** String 实参：窗口去重仍生效，返回同一值。 */
    @TestCase
    public func stringArgRoundTrip(): Unit {
        CompileCache.reset()
        let f = MarshalRs_test.compiler().compile('{ s: String => s }')
        let s = 'marshal-rs-probe-0123456789'
        var i = 0
        while (i < 200) {
            @Assert(f.call<String>([s]), s)
            i = i + 1
        }
    }

    /** 注册类透传：返回同一对象引用（pin/escape 路径）。 */
    @TestCase
    public func hostObjectRoundTrip(): Unit {
        CompileCache.reset()
        let c = MarshalRs_test.compiler()
        c.registerType<MarshalProbeUser>()
        let f = c.compile('{ u: MarshalProbeUser => u }')
        let u = MarshalProbeUser()
        let before = HandleTable.liveCount()
        var i = 0
        while (i < 100) {
            let r = f.call<MarshalProbeUser>([u])
            @Assert(refEq(r, u), true)
            i = i + 1
        }
        // 实参 pin 与返回句柄都应在收尾时归还：活槽计数回基线。
        @Assert(HandleTable.liveCount(), before)
    }

    /** 异常路径：契约失败后 `pinned` 被清，下一次正常调用不受影响。 */
    @TestCase
    public func contractFailureLeavesNoResidue(): Unit {
        CompileCache.reset()
        let f = MarshalRs_test.compiler().compile('{ n: Int64 => n + 1 }')
        try {
            let _ = f.call<Object>([Int64(1)])
            @Fail('call<Object> 应抛 CALL_CONTRACT(19)')
        } catch (e: JitException) {
            @Assert(e.code, ErrCode.CALL_CONTRACT)
        }
        @Assert(f.call<Int64>([Int64(41)]), 42)
    }

    /** 实参 pin 但返回值不含该槽：必须由 `cleanup` 释放（否则活槽单调增长）。 */
    @TestCase
    public func droppedArgIsReleasedByCleanup(): Unit {
        CompileCache.reset()
        let c = MarshalRs_test.compiler()
        c.registerType<MarshalProbeUser>()
        let f = c.compile('{ u: MarshalProbeUser => 1 }')
        let u = MarshalProbeUser()
        let before = HandleTable.liveCount()
        var i = 0
        while (i < 100) {
            @Assert(f.call<Int64>([u]), 1)
            i = i + 1
        }
        @Assert(HandleTable.liveCount(), before)
    }
}

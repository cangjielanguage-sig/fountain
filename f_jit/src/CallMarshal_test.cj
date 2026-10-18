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
import fountain::f_jit.base.ErrCode
import fountain::f_jit.base.JitException
import fountain::f_jit.base.LocalType
import fountain::f_jit.runtime.HandleTable

/** S6.3：§8.2.1 封送表 / §8.2.2 解包表 / 逃逸与清理。 */
@Test
public class CallMarshal_test {
    @TestCase
    public func scalarMarshalling(): Unit {
        let m = CallMarshal()
        @Assert(m.marshalArg(LocalType.I64, 42), 42)
        @Assert(m.marshalArg(LocalType.F64, 1.5), 0x3FF8000000000000)
        @Assert(m.marshalArg(LocalType.BOOL, true), 1)
        @Assert(m.marshalArg(LocalType.BOOL, false), 0)
    }

    @TestCase
    public func noImplicitWidening(): Unit {
        let m = CallMarshal()
        @Assert(CallMarshal_test.codeOf({ =>
            let _ = m.marshalArg(LocalType.I64, 1.5)
        }), ErrCode.CALL_CONTRACT)
        @Assert(CallMarshal_test.codeOf({ =>
            let _ = m.marshalArg(LocalType.F64, 1)
        }), ErrCode.CALL_CONTRACT)
        @Assert(CallMarshal_test.codeOf({ =>
            let _ = m.marshalArg(LocalType.STRING, 1)
        }), ErrCode.CALL_CONTRACT)
    }

    @TestCase
    public func contractErrorHasNoSite(): Unit {
        let m = CallMarshal()
        try {
            let _ = m.marshalArg(LocalType.I64, 'x')
            @Fail('未抛 19')
        } catch (e: JitException) {
            @Assert(e.code, ErrCode.CALL_CONTRACT)
            @Assert(e.site, -1)
            @Assert(e.sourcePos.isNone(), true)
        }
    }

    @TestCase
    public func handlePinnedAndCleaned(): Unit {
        let m = CallMarshal()
        let id = m.marshalArg(LocalType.STRING, 'hello')
        @Assert(id != 0, true)
        @Assert(HandleTable.getAny(id).isSome(), true)
        m.cleanup()
        @Assert(HandleTable.getAny(id).isNone(), true)
    }

    @TestCase
    public func escapedSurvivesCleanup(): Unit {
        let m = CallMarshal()
        let id = m.marshalArg(LocalType.STRING, 'kept')
        let obj = m.escapeAndGet(id)
        match (obj) {
            case s: String => @Assert(s, 'kept')
            case _ => @Fail('逃逸对象类型不符')
        }
        @Assert(m.escapedIds().size, 1)
        m.cleanup()
        @Assert(HandleTable.getAny(id).isSome(), true)
        HandleTable.release(id)
    }

    @TestCase
    public func unboxTable(): Unit {
        let m = CallMarshal()
        match (m.makeRetUnboxer(LocalType.I64)(7)) {
            case v: Int64 => @Assert(v, 7)
            case _ => @Fail('I64 解包类型不符')
        }
        match (m.makeRetUnboxer(LocalType.BOOL)(0)) {
            case v: Bool => @Assert(v, false)
            case _ => @Fail('Bool 解包类型不符')
        }
        match (m.makeRetUnboxer(LocalType.F64)(0x4008000000000000)) {
            case v: Float64 => @Assert(v, 3.0)
            case _ => @Fail('F64 解包类型不符')
        }
    }

    @TestCase
    public func marshalFailureLeavesNoResidue(): Unit {
        let m = CallMarshal()
        let id = m.marshalArg(LocalType.STRING, 'temp')
        try {
            let _ = m.marshalArg(LocalType.I64, 'bad')
        } catch (_: JitException) {
            ()
        }
        m.cleanup()
        @Assert(HandleTable.getAny(id).isNone(), true)
    }

    private static func codeOf(body: () -> Unit): Int64 {
        try {
            body()
            -999
        } catch (e: JitException) {
            e.code
        }
    }
}

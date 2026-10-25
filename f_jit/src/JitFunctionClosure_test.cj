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
import fountain::f_jit.base.ClassDescriptor
import fountain::f_jit.base.DummyDiagnosticsSink
import fountain::f_jit.base.PublicCtor
import fountain::f_jit.base.PublicField
import fountain::f_jit.base.PublicMethod
import fountain::f_jit.base.ErrCode
import fountain::f_jit.base.JitException
import fountain::f_jit.base.LocalType
import fountain::f_jit.runtime.HandleTable
import fountain::f_jit.runtime.PromotionGroup
import fountain::f_jit.test.TCase

/** Q5.6 / Q5.7 / Q5.11：逃逸闭包包装（`JitFunction` 闭包实例）。 */
@Test
public class JitFunctionClosure_test {
    private static func compiler(): Compiler {
        CompileCache.reset()
        Compiler(CompileOptions(DummyDiagnosticsSink()))
    }

    private static func closureUnit(): JitFunction {
        JitFunctionClosure_test.compiler().compile(
            '{ => let f = { x: Int64 => x + 1 }\n f }')
    }

    /** 包装器调用 = 新桥调用（`locals[0]` 闭包句柄），结果与直接 CALL_CLOSURE 一致。 */
    @TestCase
    public func wrapperCallMatchesDirectClosure(): Unit {
        let unit = JitFunctionClosure_test.closureUnit()
        let w = unit.callForFn<(Int64) -> Int64>([])
        @Assert(w.call<Int64>([41]), 42)
        let direct = JitFunctionClosure_test.compiler().compile(
            '{ => let f = { x: Int64 => x + 1 }\n f(41) }')
        @Assert(direct.call<Int64>([]), 42)
        @Assert(TCase.hit('T49/wrapper-equals-direct', w.call<Int64>([41]) == 42), true)
        w.unloadFn()
    }

    /** 失败路径：错误码与 site 与直接调用逐位一致。 */
    @TestCase
    public func wrapperErrorMatchesDirect(): Unit {
        let unit = JitFunctionClosure_test.compiler().compile(
            '{ => let f = { x: Int64 => 10 / x }\n f }')
        let w = unit.callForFn<(Int64) -> Int64>([])
        let got = JitFunctionClosure_test.catchCall(w, 0)
        let direct = JitFunctionClosure_test.compiler().compile(
            '{ => let f = { x: Int64 => 10 / x }\n f(0) }')
        let want = JitFunctionClosure_test.catchCall(direct, -1)
        @Assert(got.code, want.code)
        @Assert(got.site, want.site)
        w.unloadFn()
    }

    /** 重入 ≥3：包装闭包体内嵌套调用三层闭包。 */
    @TestCase
    public func nestedClosureDepthThree(): Unit {
        let unit = JitFunctionClosure_test.compiler().compile(
            '{ => let a = { x: Int64 => x + 1 }\n' +
            ' let b = { x: Int64 => a(x) + 1 }\n' +
            ' let c = { x: Int64 => b(x) + 1 }\n c }')
        let w = unit.callForFn<(Int64) -> Int64>([])
        @Assert(w.call<Int64>([39]), 42)
        @Assert(TCase.hit('T49/wrapper-depth3', w.call<Int64>([39]) == 42), true)
        w.unloadFn()
    }

    /** 卸载后调用 → 19（site=-1），包装器不阻止单元卸载（弱语义）。 */
    @TestCase
    public func unloadThenWrapperCallIsRejected(): Unit {
        let unit = JitFunctionClosure_test.closureUnit()
        let w = unit.callForFn<(Int64) -> Int64>([])
        @Assert(w.call<Int64>([1]), 2)
        @Assert(unit.unload(0), true)
        let e = JitFunctionClosure_test.catchCall(w, 1)
        @Assert(e.code, ErrCode.CALL_CONTRACT)
        @Assert(e.site, -1)
        w.unloadFn()
    }

    /** close 幂等、释放提升组、close 后调用 → 19。 */
    @TestCase
    public func unloadFnIsIdempotentAndReleasesGroup(): Unit {
        HandleTable.resetForTest()
        let unit = JitFunctionClosure_test.closureUnit()
        let base = HandleTable.liveCount()
        let w = unit.callForFn<(Int64) -> Int64>([])
        @Assert(HandleTable.liveCount() > base, true)
        @Assert(w.isClosed, false)
        w.unloadFn()
        @Assert(w.isClosed, true)
        w.unloadFn()
        @Assert(HandleTable.liveCount(), base)
        let e = JitFunctionClosure_test.catchCall(w, 1)
        @Assert(e.code, ErrCode.CALL_CONTRACT)
        @Assert(e.site, -1)
        @Assert(TCase.hit('T49/wrapper-close', w.isClosed && HandleTable.liveCount() == base), true)
    }

    /** 旧 ID 校验拦截：unloadFn 后的 ID 再包装 → 19。 */
    @TestCase
    public func staleClosureIdIsRejected(): Unit {
        let unit = JitFunctionClosure_test.closureUnit()
        let id = unit.call<JitClosureId>([])
        let group = match (unit.lastPromotionGroup()) {
            case Some(g) => g
            case None => @Fail('提升组缺失')
        }
        let w = JitFunction.wrapClosure(unit, id, group, -1, LocalType.NONE, Array<UInt16>())
        w.unloadFn()
        let stale = JitFunction.wrapClosure(unit, id, PromotionGroup(), -1,
            LocalType.NONE, Array<UInt16>())
        let e = JitFunctionClosure_test.catchCall(stale, 1)
        @Assert(e.code, ErrCode.CALL_CONTRACT)
        @Assert(e.site, -1)
    }

    /** 非闭包包装：unloadFn → 19（site=-1），isClosed 恒 false。 */
    @TestCase
    public func unloadFnOnEntryInstanceIsRejected(): Unit {
        let f = JitFunctionClosure_test.compiler().compile('{ => 1 }')
        @Assert(f.isClosed, false)
        var code: Int64 = 0
        var site: Int64 = 0
        try {
            f.unloadFn()
        } catch (e: JitException) {
            code = e.code
            site = e.site
        }
        @Assert(code, ErrCode.CALL_CONTRACT)
        @Assert(site, -1)
        @Assert(f.isClosed, false)
    }

    /** Q5.11：callForFn 返回可继续调用的 JitFunction；包装值直接作实参 → 19。 */
    @TestCase
    public func callForFnReturnsWrapperAndRejectsWrapperArg(): Unit {
        let unit = JitFunctionClosure_test.closureUnit()
        let w = unit.callForFn<(Int64) -> Int64>([])
        @Assert(w.call<Int64>([5]), 6)
        let nested = unit.callForFn<(Int64) -> Int64>([])
        let e = JitFunctionClosure_test.catchCallAny(nested, [nested])
        @Assert(e.code, ErrCode.CALL_CONTRACT)
        @Assert(e.site, -1)
        let labelOk = w.call<Int64>([5]) == 6 && e.code == ErrCode.CALL_CONTRACT &&
            e.site == -1
        w.unloadFn()
        nested.unloadFn()
        @Assert(TCase.hit('T49/call-for-wrapper', labelOk), true)
    }

    /** Q5.11：callForFn 实参面与 call<T> 一致——允许宿主闭包（13）作实参。 */
    @TestCase
    public func callForFnAcceptsHostClosureArgument(): Unit {
        let unit = JitFunctionClosure_test.compiler().compile(
            '{ f: (Int64) -> Int64 => let g = { x: Int64 => f(x) + 1 }\n g }')
        let f: (Int64) -> Int64 = { x => x + 1 }
        let w = unit.callForFn<(Int64) -> Int64>([f])
        @Assert(w.call<Int64>([41]), 43)
        let labelOk = w.call<Int64>([41]) == 43
        w.unloadFn()
        @Assert(TCase.hit('T30/call-for-host-closure-arg', labelOk), true)
    }

    /** Q5.11：单元持有 ClassRegistry 快照（编译期静态知识随产物）。 */
    @TestCase
    public func unitCarriesClassRegistrySnapshot(): Unit {
        CompileCache.reset()
        let c = Compiler(CompileOptions(DummyDiagnosticsSink()))
        c.registerClass(ClassDescriptor(name: 'ManualUser',
            fields: Array<PublicField>(),
            methods: Array<PublicMethod>(),
            ctors: Array<PublicCtor>()))
        let f = c.compile('{ u: ManualUser => let a = u\n a }')
        match (f.classSnapshotOf()) {
            case Some(s) => @Assert(s.classes.size, 1)
            case None => @Fail('单元未持有类快照')
        }
        @Assert(TCase.hit('T49/unit-class-snapshot',
            match (f.classSnapshotOf()) { case Some(s) => s.classes.size == 1; case None => false }), true)
    }

    /** 非返回闭包的单元调用 callForFn → 19。 */
    @TestCase
    public func callForFnOnNonClosureUnitIsRejected(): Unit {
        let f = JitFunctionClosure_test.compiler().compile('{ => 1 }')
        var code: Int64 = 0
        try {
            let _ = f.callForFn<(Int64) -> Int64>([])
        } catch (e: JitException) {
            code = e.code
        }
        @Assert(code, ErrCode.CALL_CONTRACT)
    }

    private static func catchCallAny(f: JitFunction, args: Array<Any>): JitExcInfo {
        try {
            let _ = f.call<Int64>(args)
            JitExcInfo(-999, -999)
        } catch (e: JitException) {
            JitExcInfo(e.code, e.site)
        }
    }

    private static func catchCall(f: JitFunction, arg: Int64): JitExcInfo {
        try {
            if (arg < 0) {
                let _ = f.call<Int64>([])
            } else {
                let _ = f.call<Int64>([arg])
            }
            JitExcInfo(-999, -999)
        } catch (e: JitException) {
            JitExcInfo(e.code, e.site)
        }
    }
}

/** 失败码/site 小载体。 */
protected struct JitExcInfo {
    public let code: Int64
    public let site: Int64

    public init(code: Int64, site: Int64) {
        this.code = code
        this.site = site
    }
}

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

import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_jit.base.DummyDiagnosticsSink
import fountain::f_jit.base.ErrCode
import fountain::f_jit.base.JitException
import fountain::f_jit.runtime.HandleTable

/**
 * 逃逸闭包的生命周期（本变更）：单元侧登记 + 终态级联释放、`unload()` 单一入口、
 * 闭包级排空。
 */
@Test
public class JitClosureLifecycle_test {

    private static let CLOSURE_SRC = '{ => let f = { x: Int64 => x + 1 }\n f }'
    private static let CLOSURE_SRC2 = '{ => let f = { x: Int64 => x + 2 }\n f }'
    private static let HOST_SRC = '{ cb: () -> Int64 => { => cb() } }'

    private static func compiler(): Compiler {
        CompileCache.reset()
        Compiler(CompileOptions(DummyDiagnosticsSink()))
    }

    private static func catchCall(w: JitFunction, n: Int64): JitException {
        try {
            let _ = w.call<Int64>([n])
        } catch (e: JitException) {
            return e
        }
        return JitException(ErrCode.CALL_CONTRACT, 0, 0, None, '未抛契约错误')
    }

    /** 单元卸载级联释放登记在册的逃逸闭包（不调包装释放）。 */
    @TestCase
    public func unitUnloadReleasesEscapedClosures(): Unit {
        HandleTable.resetForTest()
        let c = JitClosureLifecycle_test.compiler()
        let unit = c.compile(JitClosureLifecycle_test.CLOSURE_SRC)
        let base = HandleTable.liveCount()
        let w1 = unit.callForFn<(Int64) -> Int64>([])
        let w2 = unit.callForFn<(Int64) -> Int64>([])
        @Assert(w1.call<Int64>([41]), 42)
        @Assert(HandleTable.liveCount() > base, true)
        @Assert(unit.unload(0), true)
        let closed = w1.isClosed && w2.isClosed
        let freed = HandleTable.liveCount() == base
        let e = JitClosureLifecycle_test.catchCall(w1, 1)
        @Assert(closed, true)
        @Assert(freed, true)
        @Assert(e.code, ErrCode.CALL_CONTRACT)
        @Assert(e.site, -1)
    }

    /** B1：未经 `callForFn` 承接的提升组也随单元卸载释放（不再因覆盖丢组）。 */
    @TestCase
    public func unwrappedClosureGroupIsSweptOnUnitUnload(): Unit {
        HandleTable.resetForTest()
        let c = JitClosureLifecycle_test.compiler()
        let unit = c.compile(JitClosureLifecycle_test.CLOSURE_SRC)
        let base = HandleTable.liveCount()
        let _ = unit.call<JitClosureId>([])
        let _ = unit.call<JitClosureId>([])
        @Assert(HandleTable.liveCount() > base, true)
        @Assert(unit.unload(0), true)
        @Assert(HandleTable.liveCount(), base)
    }

    /** 包装实例释放只放自己的提升组：单元仍可调用、缓存不逐出。 */
    @TestCase
    public func wrapperUnloadOnlyReleasesOwnGroup(): Unit {
        HandleTable.resetForTest()
        let c = JitClosureLifecycle_test.compiler()
        let unit = c.compile(JitClosureLifecycle_test.CLOSURE_SRC)
        let base = HandleTable.liveCount()
        let w = unit.callForFn<(Int64) -> Int64>([])
        @Assert(w.call<Int64>([41]), 42)
        @Assert(w.unload(), true)
        @Assert(w.isClosed, true)
        @Assert(HandleTable.liveCount(), base)
        let w2 = unit.callForFn<(Int64) -> Int64>([])
        @Assert(w2.call<Int64>([1]), 2)
        let _ = c.compile(JitClosureLifecycle_test.CLOSURE_SRC)
        @Assert(CompileCache.runs(), 1)
        @Assert(w2.unload(), true)
    }

    /** B2/B5：闭包自身在飞时 `unload(0)` 回退为可用、返回 false；调用结束后可释放。 */
    @TestCase
    public func wrapperUnloadWaitsForInFlightCall(): Unit {
        HandleTable.resetForTest()
        let c = JitClosureLifecycle_test.compiler()
        let unit = c.compile(JitClosureLifecycle_test.HOST_SRC)
        let box = ArrayList<JitFunction>()
        let flag = ArrayList<Bool>()
        flag.add(true)
        let cb: () -> Int64 = { =>
            flag[0] = box[0].unload(0)
            7
        }
        let beforeWrap = HandleTable.liveCount()
        let w = unit.callForFn<() -> Int64>([cb])
        box.add(w)
        @Assert(HandleTable.liveCount() > beforeWrap, true)
        @Assert(w.call<Int64>([]), 7)
        @Assert(flag[0], false)
        @Assert(w.isClosed, false)
        @Assert(HandleTable.liveCount() > beforeWrap, true)
        @Assert(w.unload(), true)
        @Assert(w.isClosed, true)
        @Assert(HandleTable.liveCount(), beforeWrap)
    }

    /** 级联释放后再显式释放：幂等、不重复归还。 */
    @TestCase
    public func cascadeThenWrapperUnloadIsIdempotent(): Unit {
        HandleTable.resetForTest()
        let c = JitClosureLifecycle_test.compiler()
        let unit = c.compile(JitClosureLifecycle_test.CLOSURE_SRC)
        let base = HandleTable.liveCount()
        let w = unit.callForFn<(Int64) -> Int64>([])
        @Assert(unit.unload(0), true)
        let after = HandleTable.liveCount()
        @Assert(w.unload(), true)
        @Assert(w.unload(), true)
        @Assert(HandleTable.liveCount(), after)
        @Assert(after, base)
    }

    /** 级联只作用于本单元的闭包。 */
    @TestCase
    public func unitUnloadCascadeKeepsOtherUnitsIntact(): Unit {
        HandleTable.resetForTest()
        let c = JitClosureLifecycle_test.compiler()
        let ua = c.compile(JitClosureLifecycle_test.CLOSURE_SRC)
        let ub = c.compile(JitClosureLifecycle_test.CLOSURE_SRC2)
        let wa = ua.callForFn<(Int64) -> Int64>([])
        let wb = ub.callForFn<(Int64) -> Int64>([])
        let afterBoth = HandleTable.liveCount()
        @Assert(ua.unload(0), true)
        @Assert(wa.isClosed, true)
        @Assert(wb.isClosed, false)
        @Assert(wb.call<Int64>([1]), 3)
        @Assert(ub.unload(0), true)
        @Assert(wb.isClosed, true)
        @Assert(HandleTable.liveCount() < afterBoth, true)
    }

    /** 单元排空超时回退：不级联、闭包保持可用。 */
    @TestCase
    public func unloadTimeoutRollbackKeepsClosures(): Unit {
        HandleTable.resetForTest()
        let c = JitClosureLifecycle_test.compiler()
        let unit = c.compile(JitClosureLifecycle_test.HOST_SRC)
        let box = ArrayList<JitFunction>()
        let flag = ArrayList<Bool>()
        flag.add(true)
        let cb: () -> Int64 = { =>
            flag[0] = unit.unload(0)
            9
        }
        let w = unit.callForFn<() -> Int64>([cb])
        box.add(w)
        @Assert(w.call<Int64>([]), 9)
        @Assert(flag[0], false)
        @Assert(unit.isUnloaded(), false)
        @Assert(w.isClosed, false)
        @Assert(w.call<Int64>([]), 9)
        @Assert(unit.unload(0), true)
        @Assert(w.isClosed, true)
    }

    /** 状态谓词与释放来源一致。 */
    @TestCase
    public func wrapperStatePredicatesAgree(): Unit {
        HandleTable.resetForTest()
        let c = JitClosureLifecycle_test.compiler()
        let unit = c.compile(JitClosureLifecycle_test.CLOSURE_SRC)
        let w = unit.callForFn<(Int64) -> Int64>([])
        let before = !w.isClosed && !w.isUnloaded()
        @Assert(w.unload(), true)
        let afterSelf = w.isClosed && w.isUnloaded()
        let unit2 = c.compile(JitClosureLifecycle_test.CLOSURE_SRC2)
        let w2 = unit2.callForFn<(Int64) -> Int64>([])
        @Assert(unit2.unload(0), true)
        let afterCascade = w2.isClosed && w2.isUnloaded()
        @Assert(before && afterSelf && afterCascade, true)
    }
}

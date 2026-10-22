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
package fountain::f_jit.runtime

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_jit.base.ErrCode
import fountain::f_jit.base.LocalType
import fountain::f_jit.base.TypeToken
import fountain::f_jit.test.TCase

/**
 * Q4.5 H63 `host_call_trampoline` 基础语义（m2 §5）。
 *
 * 栈序（Q4.5 定案）：`[h_fn, a1..an]` —— h_fn 先入栈（helper ABI 的 `args[0]` = 最先压入），
 * 与 `CALL_CLOSURE` 的 `[ch, args…]` 完全平行。
 */
@Test
public class HostCallTrampoline_test {
    private var ctx: ?JitContext = None

    private func setup(): Unit {
        HandleTable.resetForTest()
        HandleTable.initialCapacity = 128
        HandleTable.capacityLimit = 1048576
        HandleTable.openWindow(128)
        RuntimeEnv.clearDeadline()
        MachineEnv.reset()
        IterTable.clearAll()
        match (this.ctx) {
            case Some(c) => JitContext.free(c)
            case None => ()
        }
        let c = JitContext.create(hwBase: HandleTable.windowBaseOf(), hwCap: 128, fnId: 1,
            dbgBase: 0)
        this.ctx = Some(c)
    }

    private func teardown(): Unit {
        match (this.ctx) {
            case Some(c) => JitContext.free(c)
            case None => ()
        }
        this.ctx = None
    }

    private func call(args: Array<Int64>): Int64 {
        match (this.ctx) {
            case Some(c) => invokeHelper(c, Int64(HelperId.HOST_CALL_TRAMPOLINE), args)
            case None => 0
        }
    }

    private func err(): Int64 {
        match (this.ctx) {
            case Some(c) => c.errCode
            case None => -99
        }
    }

    private func used(): Int64 {
        HandleTable.windowUsed()
    }

    private func entry(fn: Any, params: Array<UInt16>, ret: UInt16): Int64 {
        HandleTable.pin(HostCallback(fn, SignatureDescriptor(params, ret)))
    }

    /**
     * 失效面（m3 §13）：释放闭包条目后，在**复用槽**上放入签名不同的新闭包再调用——
     * 新闭包绑定自己的 plan，不命中任何旧加速；结果正确。
     */
    @TestCase
    public func slotReuseBindsFreshPlan(): Unit {
        this.setup()
        let f1: (Int64) -> Int64 = { x => x + 1 }
        let h1 = this.entry(f1, [LocalType.I64], LocalType.I64)
        @Assert(this.call([h1, 7]), 8)
        @Assert(this.err(), 0)
        HandleTable.release(h1)
        let f2: () -> Int64 = { => 55 }
        let h2 = this.entry(f2, Array<UInt16>(), LocalType.I64)
        @Assert(this.call([h2]), 55)
        @Assert(this.err(), 0)
        @Assert(TCase.hit('T56/slot-reuse', true), true)
        this.teardown()
    }

    /** H63 已登记（hid 63、名称、isFixed）。 */
    @TestCase
    public func helperIdRegistered(): Unit {
        @Assert(HelperId.HOST_CALL_TRAMPOLINE, 63u16)
        @Assert(HelperId.name(63u16), 'host_call_trampoline')
        @Assert(HelperId.isFixed(63u16), true)
        @Assert(HelperId.isFixed(66u16), false)
    }

    /** 栈底句柄 tag≠10 ⇒ 8（类型不符）。 */
    @TestCase
    public func nonHostClosureBaseRejected(): Unit {
        setup()
        let s = HandleTable.pin('not-a-callback')
        let _ = call([s])
        @Assert(err(), ErrCode.HANDLE_TYPE)
        teardown()
    }

    /** 值型逐参 + 值型返回：实参从左到右（a1=3, a2=4），返回值原样、零登记。 */
    @TestCase
    public func valueArgsAndValueReturn(): Unit {
        setup()
        let fn: Any = { a: Int64, b: Int64 => a * 10 + b }
        let h = entry(fn, [LocalType.I64, LocalType.I64], LocalType.I64)
        let before = used()
        @Assert(call([h, 3, 4]), 34)
        @Assert(err(), 0)
        @Assert(used(), before)
        teardown()
    }

    /** 句柄型实参：cell → 宿主值（String），不登记槽。 */
    @TestCase
    public func handleArgConversion(): Unit {
        setup()
        let fn: Any = { s: String => Int64(s.toRuneArray().size) }
        let h = entry(fn, [LocalType.STRING], LocalType.I64)
        let a = HandleTable.pin('abc')
        let before = used()
        @Assert(call([h, a]), 3)
        @Assert(err(), 0)
        @Assert(used(), before)
        teardown()
    }

    /** 14 实参：cell → 实例引用（不透明宿主对象，零拷贝同一对象）。 */
    @TestCase
    public func hostObjectArgConversion(): Unit {
        setup()
        let fn: Any = { o: Object =>
            match (o) {
                case m: SigMarker => m.v
                case _ => -1
            }
        }
        let h = entry(fn, [LocalType.HOST_OBJECT], LocalType.I64)
        let obj = HandleTable.pinHostObject(SigMarker(42))
        @Assert(call([h, obj]), 42)
        @Assert(err(), 0)
        teardown()
    }

    /** Bool / Float64 值型往返。 */
    @TestCase
    public func boolAndFloatConversion(): Unit {
        setup()
        let hb = entry({ => true }, Array<UInt16>(), LocalType.BOOL)
        @Assert(call([hb]), 1)
        let hf = entry({ x: Float64 => x + 0.5 }, [LocalType.F64], LocalType.F64)
        let cell = 1.25.toBits()
        let r = call([hf, Int64(cell)])
        @Assert(Float64.fromBits(UInt64(r)), 1.75)
        @Assert(err(), 0)
        teardown()
    }

    /** 引用型返回（String）⇒ 窗口登记 1 槽（hwTop 断言）。 */
    @TestCase
    public func referenceReturnRegistersOneSlot(): Unit {
        setup()
        let fn: Any = { => 'hello' }
        let h = entry(fn, Array<UInt16>(), LocalType.STRING)
        let before = used()
        let r = call([h])
        @Assert(err(), 0)
        @Assert(used(), before + 1)
        @Assert(HandleTable.tagOf(r), TypeToken.STRING)
        match (HandleTable.getAny(r)) {
            case Some(v) => match (v) {
                case s: String => @Assert(s, 'hello')
                case _ => @Fail('返回句柄类型不符')
            }
            case None => @Fail('返回句柄丢失')
        }
        teardown()
    }

    /** 14 返回 ⇒ 窗口登记 1 槽、tag=11、同一对象身份。 */
    @TestCase
    public func hostObjectReturnRegistersOneSlot(): Unit {
        setup()
        let fn: Any = { => SigMarker(9) }
        let h = entry(fn, Array<UInt16>(), LocalType.HOST_OBJECT)
        let before = used()
        let r = call([h])
        @Assert(err(), 0)
        @Assert(used(), before + 1)
        @Assert(HandleTable.tagOf(r), TypeToken.HOST_OBJECT)
        match (HandleTable.getAny(r)) {
            case Some(v) => match (v) {
                case m: SigMarker => @Assert(m.v, 9)
                case _ => @Fail('返回对象类型不符')
            }
            case None => @Fail('返回对象丢失')
        }
        teardown()
    }

    /** Unit 返回：原值 0、零登记。 */
    @TestCase
    public func unitReturn(): Unit {
        setup()
        let fn: Any = { => () }
        let h = entry(fn, Array<UInt16>(), LocalType.UNIT)
        let before = used()
        @Assert(call([h]), 0)
        @Assert(err(), 0)
        @Assert(used(), before)
        teardown()
    }

    /** 未验签条目（sig=None）⇒ 99（引擎不变式破坏，绝非宿主异常）。 */
    @TestCase
    public func unverifiedEntryIsPanic(): Unit {
        setup()
        let h = HandleTable.pin(HostCallback({ => 1 }))
        let _ = call([h])
        @Assert(err(), ErrCode.HELPER_PANIC)
        teardown()
    }

    /** 实参个数与描述符不符 ⇒ 99（汇编期保证 argc；命中即引擎缺陷）。 */
    @TestCase
    public func arityMismatchIsPanic(): Unit {
        setup()
        let h = entry({ x: Int64 => x }, [LocalType.I64], LocalType.I64)
        let _ = call([h, 1, 2])
        @Assert(err(), ErrCode.HELPER_PANIC)
        teardown()
    }

    /** 防御 -1：空实参（无 h_fn）⇒ 99。 */
    @TestCase
    public func missingHandleIsPanic(): Unit {
        setup()
        let _ = call(Array<Int64>())
        @Assert(err(), ErrCode.HELPER_PANIC)
        teardown()
    }

    // ==================================================================
    // Q4.6 异常与重入
    // ==================================================================

    /** fn 抛异常 ⇒ 21 + cause；site 保持 CALL_HOST 偏移；fail-fast（返回 0）。 */
    @TestCase
    public func hostExceptionMapsTo21WithCause(): Unit {
        setup()
        let fn: Any = { => throw HostBoom('boom-from-host') }
        let h = entry(fn, Array<UInt16>(), LocalType.I64)
        match (this.ctx) {
            case Some(c) =>
                c.site = 4242
                let _ = invokeHelper(c, Int64(HelperId.HOST_CALL_TRAMPOLINE), [h])
                @Assert(c.errCode, ErrCode.HOST_EXCEPTION)
                @Assert(c.site, 4242)
                match (HostFault.causeOf(c)) {
                    case Some(t) =>
                        @Assert(t.contains('boom-from-host'), true)
                    case None => @Fail('21 必须附带 cause')
                }
            case None => @Fail('ctx 未初始化')
        }
        teardown()
    }

    /** 引擎侧失败（未验签）保持 99，且不产生 cause（21 与 99 严格区分）。 */
    @TestCase
    public func engineFailureStays99WithoutCause(): Unit {
        setup()
        let h = HandleTable.pin(HostCallback({ => 1 }))
        let _ = call([h])
        @Assert(err(), ErrCode.HELPER_PANIC)
        match (this.ctx) {
            case Some(c) => @Assert(HostFault.causeOf(c).isNone(), true)
            case None => @Fail('ctx 未初始化')
        }
        teardown()
    }

    /** cause 通道调用私有：两个 ctx 的失败互不串扰。 */
    @TestCase
    public func causeIsPerCallPrivate(): Unit {
        setup()
        let c1 = JitContext.create(hwBase: HandleTable.windowBaseOf(), hwCap: 128, fnId: 1,
            dbgBase: 0)
        let c2 = JitContext.create(hwBase: HandleTable.windowBaseOf(), hwCap: 128, fnId: 2,
            dbgBase: 0)
        let h1 = entry({ => throw HostBoom('first') }, Array<UInt16>(), LocalType.I64)
        let h2 = entry({ => throw HostBoom('second') }, Array<UInt16>(), LocalType.I64)
        let _ = invokeHelper(c1, Int64(HelperId.HOST_CALL_TRAMPOLINE), [h1])
        let _ = invokeHelper(c2, Int64(HelperId.HOST_CALL_TRAMPOLINE), [h2])
        @Assert(c1.errCode, ErrCode.HOST_EXCEPTION)
        @Assert(c2.errCode, ErrCode.HOST_EXCEPTION)
        match (HostFault.causeOf(c1)) {
            case Some(t) => @Assert(t.contains('first') && !t.contains('second'), true)
            case None => @Fail('c1 cause 缺失')
        }
        match (HostFault.causeOf(c2)) {
            case Some(t) => @Assert(t.contains('second') && !t.contains('first'), true)
            case None => @Fail('c2 cause 缺失')
        }
        JitContext.free(c1)
        JitContext.free(c2)
        teardown()
    }

    /**
     * 重入（深度 3）：闭包内再调 JIT —— 新 ctx（LibC.malloc/free）、独立事务；
     * 内层 21 不覆盖外层错误槽，各层 cause 独立。
     *
     * 回传编码：cb2 = e3*10 + (cause3?1:0) = 211（ctx3 失败，cb2 正常返回）；
     * cb1 = e2*1000 + r2 = 0*1000 + 211 = 211（ctx2 成功——内层 21 不外溢）。
     */
    @TestCase
    public func reentrancyDepth3IsolatesTransactions(): Unit {
        setup()
        NativeMem.resetCounters()
        let h3 = entry({ => throw HostBoom('depth-3') }, Array<UInt16>(), LocalType.I64)
        let cb2: Any = { =>
            let c3 = JitContext.create(hwBase: HandleTable.windowBaseOf(), hwCap: 128,
                fnId: 3, dbgBase: 0)
            let _ = invokeHelper(c3, Int64(HelperId.HOST_CALL_TRAMPOLINE), [h3])
            let e3 = c3.errCode
            let has3 = if (HostFault.causeOf(c3).isSome()) { 1 } else { 0 }
            JitContext.free(c3)
            e3 * 10 + has3
        }
        let h2 = entry(cb2, Array<UInt16>(), LocalType.I64)
        let cb1: Any = { =>
            let c2 = JitContext.create(hwBase: HandleTable.windowBaseOf(), hwCap: 128,
                fnId: 2, dbgBase: 0)
            let r2 = invokeHelper(c2, Int64(HelperId.HOST_CALL_TRAMPOLINE), [h2])
            let e2 = c2.errCode
            JitContext.free(c2)
            e2 * 1000 + r2
        }
        let h1 = entry(cb1, Array<UInt16>(), LocalType.I64)
        let r = call([h1])
        @Assert(r, 211)
        @Assert(err(), 0) // 外层成功：内层失败不外溢
        @Assert(NativeMem.outstanding(), 0) // 新 ctx 全部配对释放
        teardown()
    }

    /** JitContext.free 清理本次调用的 cause 旁路（无跨调用残留）。 */
    @TestCase
    public func freeClearsFaultRecord(): Unit {
        setup()
        let c = JitContext.create(hwBase: HandleTable.windowBaseOf(), hwCap: 128, fnId: 9,
            dbgBase: 0)
        let h = entry({ => throw HostBoom('ephemeral') }, Array<UInt16>(), LocalType.I64)
        let _ = invokeHelper(c, Int64(HelperId.HOST_CALL_TRAMPOLINE), [h])
        @Assert(HostFault.causeOf(c).isSome(), true)
        JitContext.free(c)
        @Assert(HostFault.causeOf(c).isNone(), true)
        teardown()
    }
}

/** 宿主闭包抛出的测试异常。 */
public class HostBoom <: Exception {
    public init(msg: String) {
        super(msg)
    }
}

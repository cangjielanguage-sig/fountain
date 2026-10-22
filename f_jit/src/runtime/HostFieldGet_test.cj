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

/** Q4.7 的探针类（只用于字段访问用例；不注册到任何类表）。 */
public class FieldProbe {
    public var age: Int64 = 0
    public var name: String = ''
    public var child: ChildProbe = ChildProbe()

    public init() {}
}

/** 14 型字段的目标对象（身份断言用）。 */
public class ChildProbe {
    public var city: String = ''

    public init() {}
}

/**
 * Q4.7 H64 `host_get_field`（m2 §12.2）。
 *
 * 语义：值型字段直取原值（零登记）；句柄型字段（4–14）marshal 为句柄（条件分配型 ⇒ 登记 1 槽）；
 * `obj` 非 tag 11 ⇒ 8；字段 index 未登记 / 负值 ⇒ 99（运行期防御，理论不可达）。
 *
 * 字段表访问：注册项 = `(index, type, mutable, accepts, getter, setter)`；H64 按
 * 「index 命中且 `accepts(obj)` 为真」选择唯一访问器（index 是类内序号，跨类可重复）。
 */
@Test
public class HostFieldGet_test {
    private var ctx: ?JitContext = None

    private func setup(): Unit {
        HandleTable.resetForTest()
        HandleTable.initialCapacity = 128
        HandleTable.capacityLimit = 1048576
        HandleTable.openWindow(128)
        HostFieldTable.resetForTest()
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

    private func call(a: Array<Int64>): Int64 {
        match (this.ctx) {
            case Some(c) => invokeHelper(c, Int64(HelperId.HOST_GET_FIELD), a)
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

    private func register(index: UInt16, t: UInt16, mutable: Bool, getter: (Object) -> Any,
        setter: (Object, Any) -> Unit): Unit {
        HostFieldTable.register(index: index, `type`: t, mutable: mutable,
            accepts: { o => o is FieldProbe }, getter: getter, setter: setter)
    }

    /** H64/H65 已登记（hid 64/65、名称、isFixed；66–68 仍保留）。 */
    @TestCase
    public func helperIdsRegistered(): Unit {
        @Assert(HelperId.HOST_GET_FIELD, 64u16)
        @Assert(HelperId.HOST_SET_FIELD, 65u16)
        @Assert(HelperId.name(64u16), 'host_get_field')
        @Assert(HelperId.name(65u16), 'host_set_field')
        @Assert(HelperId.isFixed(64u16), true)
        @Assert(HelperId.isFixed(65u16), true)
        @Assert(HelperId.isFixed(66u16), false)
    }

    /** 值型字段：直取原值、**零登记**。 */
    @TestCase
    public func valueFieldIsReadWithoutRegistration(): Unit {
        setup()
        let p = FieldProbe()
        p.age = 42
        let h = HandleTable.pinHostObject(p)
        register(1u16, LocalType.I64, true,
            { o => match (o) { case x: FieldProbe => x.age; case _ => 0 } },
            { o, v => match ((o, v)) {
                case (x: FieldProbe, n: Int64) => x.age = n
                case _ => ()
            } })
        let before = used()
        @Assert(call([h, 1]), 42)
        @Assert(err(), 0)
        @Assert(used(), before)
        teardown()
    }

    /** 句柄型字段（String）：marshal 为句柄，窗口登记 1 槽。 */
    @TestCase
    public func handleFieldRegistersOneSlot(): Unit {
        setup()
        let p = FieldProbe()
        p.name = 'abc'
        let h = HandleTable.pinHostObject(p)
        register(2u16, LocalType.STRING, true,
            { o => match (o) { case x: FieldProbe => x.name; case _ => '' } },
            { o, v => match (o) { case x: FieldProbe => x.name = ''; case _ => () } })
        let before = used()
        let r = call([h, 2])
        @Assert(err(), 0)
        @Assert(used(), before + 1)
        @Assert(HandleTable.fetchString(r), 'abc')
        teardown()
    }

    /** 14 型字段：返回宿主对象句柄（tag 11）、同一对象身份。 */
    @TestCase
    public func hostObjectFieldKeepsIdentity(): Unit {
        setup()
        let p = FieldProbe()
        let child = ChildProbe()
        child.city = '杭州'
        p.child = child
        let h = HandleTable.pinHostObject(p)
        register(3u16, LocalType.HOST_OBJECT, true,
            { o => match (o) { case x: FieldProbe => x.child; case _ => ChildProbe() } },
            { o, v => match (o) {
                case x: FieldProbe => match (v) { case c: ChildProbe => x.child = c; case _ => () }
                case _ => ()
            } })
        let before = used()
        let r = call([h, 3])
        @Assert(err(), 0)
        @Assert(used(), before + 1)
        @Assert(HandleTable.tagOf(r), TypeToken.HOST_OBJECT)
        let back = HandleTable.fetchHostObject(r)
        @Assert(refEq(back, child), true)
        teardown()
    }

    /** obj 的 tag ≠ 11 ⇒ 8（既有 fetch 语义）。 */
    @TestCase
    public func nonHostObjectIsRejected(): Unit {
        setup()
        let s = HandleTable.pin('not-an-object')
        register(1u16, LocalType.I64, true,
            { o => 0 },
            { o, v => () })
        let _ = call([s, 1])
        @Assert(err(), ErrCode.HANDLE_TYPE)
        teardown()
    }

    /** 未登记 index / 负 index ⇒ 99（运行期防御）。 */
    @TestCase
    public func unknownOrNegativeIndexPanics(): Unit {
        setup()
        let p = FieldProbe()
        let h = HandleTable.pinHostObject(p)
        register(1u16, LocalType.I64, true,
            { o => 7 },
            { o, v => () })
        let _ = call([h, 9])
        @Assert(err(), ErrCode.HELPER_PANIC)
        match (this.ctx) {
            case Some(c) => c.errCode = 0
            case None => ()
        }
        let _ = call([h, -1])
        @Assert(err(), ErrCode.HELPER_PANIC)
        teardown()
    }

    /** 访问器返回值与声明类型不符 ⇒ 99（类型防御）。 */
    @TestCase
    public func accessorTypeMismatchPanics(): Unit {
        setup()
        let p = FieldProbe()
        let h = HandleTable.pinHostObject(p)
        register(1u16, LocalType.I64, true,
            { o => 'wrong' },
            { o, v => () })
        let _ = call([h, 1])
        @Assert(err(), ErrCode.HELPER_PANIC)
        teardown()
    }

    /** 访问器执行期异常 → 21（宿主异常专用码，v0.8.19 §13-6），cause 可读。 */
    @TestCase
    public func accessorExceptionMapsTo21(): Unit {
        setup()
        let p = FieldProbe()
        let h = HandleTable.pinHostObject(p)
        register(1u16, LocalType.I64, true,
            { o =>
                throw Exception('getter-boom')
            },
            { o, v => () })
        let _ = call([h, 1])
        @Assert(err(), ErrCode.HOST_EXCEPTION)
        match (this.ctx) {
            case Some(c) => @Assert(HostFault.causeOf(c).isSome(), true)
            case None => @Fail('ctx 缺失')
        }
        teardown()
    }
}

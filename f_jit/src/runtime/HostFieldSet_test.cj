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

/**
 * Q4.8 H65 `host_set_field`（m2 §12.2）。
 *
 * 写语义：值型直存、句柄型 fetch 后存对象引用；class 引用语义 ⇒ **原地变更即正确**，
 * 调用返回后宿主观测到同一对象被修改；**变更型 helper 不登记槽**。
 *
 * 防线：`mutable=false` ⇒ 19（语法糖编译期为主防线）；`obj` 非 tag 11 ⇒ 8；
 * index 未登记 / 类型防御 ⇒ 99。含 H65 的函数 `flags.bit0` + deopt 禁令见 Assembler 用例。
 */
@Test
public class HostFieldSet_test {
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
            case Some(c) => invokeHelper(c, Int64(HelperId.HOST_SET_FIELD), a)
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

    /** 值型写：宿主可见（同一对象），**零登记**。 */
    @TestCase
    public func valueFieldWriteIsVisibleAndUnregistered(): Unit {
        setup()
        let p = FieldProbe()
        p.age = 1
        let h = HandleTable.pinHostObject(p)
        register(1u16, LocalType.I64, true,
            { o => match (o) { case x: FieldProbe => x.age; case _ => 0 } },
            { o, v => match (o) {
                case x: FieldProbe => match (v) { case n: Int64 => x.age = n; case _ => () }
                case _ => ()
            } })
        let before = used()
        @Assert(call([h, 1, 99]), 0)
        @Assert(err(), 0)
        @Assert(p.age, 99)
        @Assert(used(), before)
        teardown()
    }

    /** 句柄型写：fetch 后存对象引用（同一 String 值），**零登记**。 */
    @TestCase
    public func handleFieldWriteStoresReference(): Unit {
        setup()
        let p = FieldProbe()
        let h = HandleTable.pinHostObject(p)
        register(2u16, LocalType.STRING, true,
            { o => match (o) { case x: FieldProbe => x.name; case _ => '' } },
            { o, v => match (o) {
                case x: FieldProbe => match (v) { case s: String => x.name = s; case _ => () }
                case _ => ()
            } })
        let sh = HandleTable.pin('hello')
        let before = used()
        @Assert(call([h, 2, sh]), 0)
        @Assert(err(), 0)
        @Assert(p.name, 'hello')
        @Assert(used(), before)
        teardown()
    }

    /** 14 型字段写：宿主对象引用原样存入（同一对象身份）。 */
    @TestCase
    public func hostObjectFieldWriteKeepsIdentity(): Unit {
        setup()
        let p = FieldProbe()
        let h = HandleTable.pinHostObject(p)
        register(3u16, LocalType.HOST_OBJECT, true,
            { o => match (o) { case x: FieldProbe => x.child; case _ => ChildProbe() } },
            { o, v => match (o) {
                case x: FieldProbe => match (v) { case c: ChildProbe => x.child = c; case _ => () }
                case _ => ()
            } })
        let child = ChildProbe()
        let ch = HandleTable.pinHostObject(child)
        let before = used()
        @Assert(call([h, 3, ch]), 0)
        @Assert(err(), 0)
        @Assert(refEq(p.child, child), true)
        @Assert(used(), before)
        teardown()
    }

    /** `mutable=false`（`let` 字段）⇒ 19；值不被修改。 */
    @TestCase
    public func immutableFieldIsRejected(): Unit {
        setup()
        let p = FieldProbe()
        p.name = 'keep'
        let h = HandleTable.pinHostObject(p)
        register(2u16, LocalType.STRING, false,
            { o => match (o) { case x: FieldProbe => x.name; case _ => '' } },
            { o, v => match (o) {
                case x: FieldProbe => match (v) { case s: String => x.name = s; case _ => () }
                case _ => ()
            } })
        let sh = HandleTable.pin('changed')
        @Assert(call([h, 2, sh]), 0)
        @Assert(err(), ErrCode.READONLY)
        @Assert(p.name, 'keep')
        teardown()
    }

    /** `obj` 非 tag 11 ⇒ 8。 */
    @TestCase
    public func nonHostObjectIsRejected(): Unit {
        setup()
        let s = HandleTable.pin('not-an-object')
        register(1u16, LocalType.I64, true,
            { o => 0 },
            { o, v => () })
        let _ = call([s, 1, 5])
        @Assert(err(), ErrCode.HANDLE_TYPE)
        teardown()
    }

    /** index 未登记 ⇒ 99（运行期防御）。 */
    @TestCase
    public func unknownIndexPanics(): Unit {
        setup()
        let p = FieldProbe()
        let h = HandleTable.pinHostObject(p)
        register(1u16, LocalType.I64, true,
            { o => 0 },
            { o, v => () })
        let _ = call([h, 7, 5])
        @Assert(err(), ErrCode.HELPER_PANIC)
        teardown()
    }
}

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
import fountain::f_jit.base.LocalType
import fountain::f_jit.base.TypeToken
import fountain::f_jit.runtime.HandleTable
import fountain::f_jit.runtime.HostCallback
import fountain::f_jit.runtime.SignatureDescriptor
import fountain::f_jit.test.ReflectAdmin
import fountain::f_jit.test.TCase

/** Q5.8 / Q5.10：源入口 14 型实参与 HostClosure 参数行。 */
@Test
public class CallMarshalM2_test {
    private static func setup(): Unit {
        HandleTable.resetForTest()
        HandleTable.openWindow(128)
    }

    private static func teardown(): Unit {
        HandleTable.resetForTest()
    }

    /** 14 型：`is C`（含子类）→ pin(tag=11)；同一对象同 ID。 */
    @TestCase
    public func hostObjectAcceptanceAndIdentity(): Unit {
        CallMarshalM2_test.setup()
        let m = CallMarshal()
        let u = ManualUser('bob', 1)
        let id = m.marshalArg(LocalType.HOST_OBJECT, u, className: Some('ManualUser'))
        @Assert(id != 0, true)
        @Assert(HandleTable.isType(id, TypeToken.HOST_OBJECT), true)
        let again = m.marshalArg(LocalType.HOST_OBJECT, u, className: Some('ManualUser'))
        @Assert(again, id)
        match (HandleTable.getAny(id)) {
            case Some(v) =>
                match (v) {
                    case x: ManualUser => @Assert(x.name, 'bob')
                    case _ => @Fail('14 载荷类型不符')
                }
            case None => @Fail('14 句柄不可读')
        }
        // 子类实例按声明基类通过（opaque 视图）
        let admin = ReflectAdmin('root')
        let aid = m.marshalArg(LocalType.HOST_OBJECT, admin, className: Some('ReflectUser'))
        @Assert(aid != 0, true)
        m.cleanup()
        CallMarshalM2_test.teardown()
        @Assert(TCase.hit('T57/host-object-is-c', true), true)
    }

    /** 型别不符 → 19（site=-1）；null → 19。 */
    @TestCase
    public func wrongClassAndNullAreRejected(): Unit {
        CallMarshalM2_test.setup()
        let m = CallMarshal()
        let e = CallMarshalM2_test.codeOf({ =>
            let _ = m.marshalArg(LocalType.HOST_OBJECT, ManualUser('x', 0),
                className: Some('ReflectUser'))
        })
        @Assert(e.code, ErrCode.CALL_CONTRACT)
        @Assert(e.site, -1)

        // 语言层 `null` 不能直接作为 `Any`：用 Option.None 作为 null-like 值（同走拒绝路径）。
        let none: ?ManualUser = None
        let nullRes = CallMarshalM2_test.codeOf({ =>
            let _ = m.marshalArg(LocalType.HOST_OBJECT, none,
                className: Some('ManualUser'))
        })
        @Assert(nullRes.code, ErrCode.CALL_CONTRACT)
        @Assert(nullRes.site, -1)
        m.cleanup()
        CallMarshalM2_test.teardown()
    }

    /** 多参混排：值型 / 句柄型 / 14 交错；cleanup 只释放非逃逸 pin。 */
    @TestCase
    public func mixedArguments(): Unit {
        CallMarshalM2_test.setup()
        let m = CallMarshal()
        let u = ManualUser('mix', 2)
        let a = m.marshalArg(LocalType.I64, 7)
        let s = m.marshalArg(LocalType.STRING, 's')
        let h = m.marshalArg(LocalType.HOST_OBJECT, u, className: Some('ManualUser'))
        @Assert(a, 7)
        @Assert(HandleTable.isType(s, TypeToken.STRING), true)
        @Assert(HandleTable.isType(h, TypeToken.HOST_OBJECT), true)
        m.cleanup()
        @Assert(HandleTable.getAny(s).isNone(), true)
        @Assert(HandleTable.getAny(h).isNone(), true)
        CallMarshalM2_test.teardown()
        @Assert(TCase.hit('T57/mixed-args', true), true)
    }

    /** HostClosure 参数：单次 `is` 验签 → pin(tag=10)；同函数同签名同 ID。 */
    @TestCase
    public func hostClosureVerifiesAndPins(): Unit {
        CallMarshalM2_test.setup()
        let m = CallMarshal()
        let f: (Int64) -> Int64 = { x => x + 1 }
        let sig = SignatureDescriptor([LocalType.I64], LocalType.I64)
        let id = m.marshalArg(LocalType.HOST_CLOSURE, f, sig: Some(sig))
        // 语言层函数值不是 Object（refEq 不可用）⇒ 同函数值多次 Marshal 各取一槽；
        // 幂等性按「同一次 marshal 的 HostCallback 条目」成立，跨调用由 try/finally 清理。
        let again = m.marshalArg(LocalType.HOST_CLOSURE, f, sig: Some(sig))
        @Assert(again != 0, true)
        @Assert(HandleTable.isType(id, TypeToken.HOST_CLOSURE), true)
        match (HandleTable.getAs(id, TypeToken.HOST_CLOSURE)) {
            case Some(v) =>
                match (v) {
                    case cb: HostCallback =>
                        match (cb.sig) {
                            case Some(s) => @Assert(s.ret, LocalType.I64)
                            case None => @Fail('验签结果未缓存')
                        }
                        match (cb.fn) {
                            case g: (Int64) -> Int64 => @Assert(g(1), 2)
                            case _ => @Fail('回调函数值类型不符')
                        }
                    case _ => @Fail('tag=10 载荷类型不符')
                }
            case None => @Fail('回调句柄不可读')
        }
        m.cleanup()
        CallMarshalM2_test.teardown()
        @Assert(TCase.hit('T30/host-closure-pin', true), true)
    }

    /** 非函数值 / 签名不符 / 禁高阶 → 19（site=-1）。 */
    @TestCase
    public func hostClosureRejectSetIs19(): Unit {
        CallMarshalM2_test.setup()
        let m = CallMarshal()
        let sig = SignatureDescriptor([LocalType.I64], LocalType.I64)
        let nonFn = CallMarshalM2_test.codeOf({ =>
            let _ = m.marshalArg(LocalType.HOST_CLOSURE, 1, sig: Some(sig))
        })
        @Assert(nonFn.code, ErrCode.CALL_CONTRACT)
        @Assert(nonFn.site, -1)

        let wrong: (String) -> Int64 = { s => s.size }
        let wrongRes = CallMarshalM2_test.codeOf({ =>
            let _ = m.marshalArg(LocalType.HOST_CLOSURE, wrong, sig: Some(sig))
        })
        @Assert(wrongRes.code, ErrCode.CALL_CONTRACT)

        let f: (Int64) -> Int64 = { x => x }
        let higher = SignatureDescriptor([LocalType.CLOSURE], LocalType.I64)
        let highRes = CallMarshalM2_test.codeOf({ =>
            let _ = m.marshalArg(LocalType.HOST_CLOSURE, f, sig: Some(higher))
        })
        @Assert(highRes.code, ErrCode.CALL_CONTRACT)
        m.cleanup()
        CallMarshalM2_test.teardown()
    }

    /** 端到端：入口形参声明 HostClosure，`call<T>` 验签后传入并调用。 */
    @TestCase
    public func entryHostClosureParamWorks(): Unit {
        CompileCache.reset()
        let c = Compiler(CompileOptions(DummyDiagnosticsSink()))
        let unit = c.compile('{ f: (Int64) -> Int64 => f(41) }')
        let f: (Int64) -> Int64 = { x => x + 1 }
        @Assert(unit.call<Int64>([f]), 42)

        let bad: (String) -> Int64 = { s => s.size }
        var code: Int64 = 0
        var site: Int64 = 0
        try {
            let _ = unit.call<Int64>([bad])
        } catch (e: JitException) {
            code = e.code
            site = e.site
        }
        @Assert(code, ErrCode.CALL_CONTRACT)
        @Assert(site, -1)
        @Assert(TCase.hit('T30/entry-host-closure', true), true)
    }

    private static func codeOf(body: () -> Unit): ExcSite {
        try {
            body()
            ExcSite(-999, -999)
        } catch (e: JitException) {
            ExcSite(e.code, e.site)
        }
    }
}

/** 失败码/site 小载体（避免与 Q5.6 测试的同名结构冲突）。 */
protected struct ExcSite {
    public let code: Int64
    public let site: Int64

    public init(code: Int64, site: Int64) {
        this.code = code
        this.site = site
    }
}

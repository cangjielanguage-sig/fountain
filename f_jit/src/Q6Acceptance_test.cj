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

import std.collection.*
import std.sync.*
import std.reflect.TypeInfo
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_base.UnsafeBytes
import fountain::f_jit.base.ClassDescriptor
import fountain::f_jit.base.DummyDiagnosticsSink
import fountain::f_jit.base.ErrCode
import fountain::f_jit.base.JitException
import fountain::f_jit.base.LocalType
import fountain::f_jit.base.PredefinedFunction
import fountain::f_jit.base.PublicCtor
import fountain::f_jit.base.PublicField
import fountain::f_jit.base.PublicMethod
import fountain::f_jit.base.SourceCompileException
import fountain::f_jit.runtime.HandleTable
import fountain::f_jit.runtime.HelperId

import fountain::f_jit.runtime.HostCallback
import fountain::f_jit.runtime.HostFault
import fountain::f_jit.runtime.HostFieldTable
import fountain::f_jit.runtime.JitContext
import fountain::f_jit.runtime.NativeMem
import fountain::f_jit.runtime.PromotionGroup
import fountain::f_jit.runtime.RuntimeEnv
import fountain::f_jit.runtime.SignatureDescriptor
import fountain::f_jit.runtime.SignatureVerifier
import fountain::f_jit.base.TypeToken
import fountain::f_jit.runtime.UserHelperEntry
import fountain::f_jit.runtime.UserHelperTable
import fountain::f_jit.runtime.invokeHelper
import fountain::f_jit.test.ReflectAdmin
import fountain::f_jit.test.ReflectUser
import fountain::f_jit.test.TCase

/** T60 栈帧断言的抛出点（第一帧应为本函数）。 */
public func q6ThrowBoom(): Nothing {
    throw Q6HostBoom('deep-boom')
}

/** T60 / T31 的宿主异常夹具（测试包内私有，不跨包导出）。 */
public class Q6HostBoom <: Exception {
    public init(msg: String) {
        super(msg)
    }
}

/** T34/T57 的“型别不符”夹具（不是 `Q6Entity`）。 */
public class Q6Order {
    public var id: Int64

    public init(id: Int64) {
        this.id = id
    }
}

/** 嵌套构造 / 14 型字段夹具。 */
public class Q6Child {
    public var city: String

    public init(city: String) {
        this.city = city
    }
}

/** 手工类注册的宿主实体（字段 / 方法 / 构造器 / 14 链 / `let` 字段）。 */
public open class Q6Entity {
    public var name: String
    public var age: Int64
    public var child: Q6Child
    public let tag: Int64

    public init() {
        this.name = ''
        this.age = 0
        this.child = Q6Child('')
        this.tag = 7
    }

    public init(name: String) {
        this.name = name
        this.age = 0
        this.child = Q6Child('')
        this.tag = 7
    }

    public init(name: String, age: Int64) {
        this.name = name
        this.age = age
        this.child = Q6Child('')
        this.tag = 7
    }

    public init(child: Q6Child) {
        this.name = ''
        this.age = 0
        this.child = child
        this.tag = 7
    }

    public func greet(s: String): String {
        'hi ${s}'
    }

    public func self(): Q6Entity {
        this
    }
}

/** Q6Entity 子类（T57：手工访问器 `o is C` 天然支持继承）。 */
public class Q6SubEntity <: Q6Entity {
    public init(name: String) {
        super(name)
    }
}

/** 构造适配器抛异常的夹具（T60 第三面）。 */
public class Q6BoomCtor {
    public init() {}
}

/** 重载歧义夹具：两条同签名构造器。 */
public class Q6Ambig {
    public init(v: Int64) {
        let _ = v
    }
}

/** Q6 验收（T30–T36、T49、T54、T55、T57–T60）。 */
@Test
public class Q6Acceptance_test {
    private static let created = ArrayList<Q6Entity>()

    // ==================================================================
    // 夹具：类注册 + 字段访问器 + 预定义函数
    // ==================================================================

    private static func entityDescriptor(c: Compiler): ClassDescriptor {
        let greet = PredefinedFunction('q6_entity_greet',
            [LocalType.HOST_OBJECT, LocalType.STRING], LocalType.STRING, { args =>
                match (args[0]) {
                    case e: Q6Entity =>
                        match (args[1]) {
                            case s: String => e.greet(s)
                            case _ => ''
                        }
                    case _ => ''
                }
            })
        let selfFn = PredefinedFunction('q6_entity_self', [LocalType.HOST_OBJECT],
            LocalType.HOST_OBJECT, { args => args[0] })
        c.registerFunction(greet)
        c.registerFunction(selfFn)
        ClassDescriptor(name: 'Q6Entity',
            fields: [
                PublicField(name: 'name', `type`: LocalType.STRING, index: 0u16,
                    mutable: true, typeRef: None),
                PublicField(name: 'age', `type`: LocalType.I64, index: 1u16,
                    mutable: true, typeRef: None),
                PublicField(name: 'child', `type`: LocalType.HOST_OBJECT, index: 2u16,
                    mutable: true, typeRef: Some('Q6Child')),
                PublicField(name: 'tag', `type`: LocalType.I64, index: 3u16,
                    mutable: false, typeRef: None)
            ],
            methods: [
                PublicMethod(name: 'greet', bind: greet),
                PublicMethod(name: 'self', bind: selfFn)
            ],
            ctors: [
                PublicCtor(params: Array<UInt16>(), adapter: { _ =>
                    let e = Q6Entity()
                    Q6Acceptance_test.created.add(e)
                    e
                }),
                PublicCtor(params: [LocalType.STRING], adapter: { args =>
                    let e = match (args[0]) {
                        case s: String => Q6Entity(s)
                        case _ => Q6Entity()
                    }
                    Q6Acceptance_test.created.add(e)
                    e
                }),
                PublicCtor(params: [LocalType.STRING, LocalType.I64], adapter: { args =>
                    let e = match ((args[0], args[1])) {
                        case (s: String, n: Int64) => Q6Entity(s, n)
                        case _ => Q6Entity()
                    }
                    Q6Acceptance_test.created.add(e)
                    e
                }),
                PublicCtor(params: [LocalType.HOST_OBJECT], adapter: { args =>
                    let e = match (args[0]) {
                        case ch: Q6Child => Q6Entity(ch)
                        case _ => Q6Entity()
                    }
                    Q6Acceptance_test.created.add(e)
                    e
                })
            ])
    }

    private static func childDescriptor(): ClassDescriptor {
        ClassDescriptor(name: 'Q6Child',
            fields: [
                PublicField(name: 'city', `type`: LocalType.STRING, index: 0u16,
                    mutable: true, typeRef: None)
            ],
            methods: Array<PublicMethod>(),
            ctors: [PublicCtor(params: [LocalType.STRING], adapter: { args =>
                match (args[0]) {
                    case s: String => Q6Child(s)
                    case _ => Q6Child('')
                }
            })])
    }

    private static func registerFields(): Unit {
        HostFieldTable.register(index: 0u16, `type`: LocalType.STRING, mutable: true,
            accepts: { o => o is Q6Entity },
            getter: { o => match (o) { case e: Q6Entity => e.name; case _ => '' } },
            setter: { o, v => match ((o, v)) {
                case (e: Q6Entity, s: String) => e.name = s
                case _ => ()
            } })
        HostFieldTable.register(index: 1u16, `type`: LocalType.I64, mutable: true,
            accepts: { o => o is Q6Entity },
            getter: { o => match (o) { case e: Q6Entity => e.age; case _ => 0 } },
            setter: { o, v => match ((o, v)) {
                case (e: Q6Entity, n: Int64) => e.age = n
                case _ => ()
            } })
        HostFieldTable.register(index: 2u16, `type`: LocalType.HOST_OBJECT, mutable: true,
            accepts: { o => o is Q6Entity },
            getter: { o => match (o) { case e: Q6Entity => e.child; case _ => Q6Child('') } },
            setter: { o, v => match ((o, v)) {
                case (e: Q6Entity, ch: Q6Child) => e.child = ch
                case _ => ()
            } })
        HostFieldTable.register(index: 3u16, `type`: LocalType.I64, mutable: false,
            accepts: { o => o is Q6Entity },
            getter: { o => match (o) { case e: Q6Entity => e.tag; case _ => 0 } },
            setter: { o, v =>
                let _ = (o, v)
                ()
            })
        HostFieldTable.register(index: 0u16, `type`: LocalType.STRING, mutable: true,
            accepts: { o => o is Q6Child },
            getter: { o => match (o) { case c: Q6Child => c.city; case _ => '' } },
            setter: { o, v => match ((o, v)) {
                case (c: Q6Child, s: String) => c.city = s
                case _ => ()
            } })
    }

    private static func newCompiler(): Compiler {
        CompileCache.reset()
        HandleTable.resetForTest()
        HostFieldTable.resetForTest()
        UserHelperTable.resetForTest()
        Q6Acceptance_test.created.clear()
        NativeMem.resetCounters()
        RuntimeEnv.clearDeadline()
        let c = Compiler(CompileOptions(DummyDiagnosticsSink()))
        c.registerClass(Q6Acceptance_test.entityDescriptor(c))
        c.registerClass(Q6Acceptance_test.childDescriptor())
        Q6Acceptance_test.registerFields()
        c
    }

    private static func errOf(body: () -> Unit): Q6Err {
        try {
            body()
            Q6Err(-999, -999, None)
        } catch (e: JitException) {
            Q6Err(e.code, e.site, e.cause)
        }
    }

    private static func sceneOk(ok: Bool, id: String): Bool {
        TCase.hit(id, ok)
    }

    // ==================================================================
    // Q6.1 T30 验签与 Marshal
    // ==================================================================

    /** 失败面全 19（site=-1）：非函数值 / 元数 / 逐参 / 返回 / null。 */
    @TestCase
    public func t30EntryMarshalFailureSetIs19(): Unit {
        let c = Q6Acceptance_test.newCompiler()
        let one = c.compile('{ f: (Int64) -> Int64 => f(1) }')
        let zero = c.compile('{ f: () -> Int64 => f() }')
        var ok = true
        let e1 = Q6Acceptance_test.errOf({ => let _ = one.call<Int64>([1]) })
        ok = ok && e1.code == ErrCode.CALL_CONTRACT && e1.site == -1
        let e2 = Q6Acceptance_test.errOf({ =>
            let _ = zero.call<Int64>([{ x: Int64 => x }])
        })
        ok = ok && e2.code == ErrCode.CALL_CONTRACT && e2.site == -1
        let e3 = Q6Acceptance_test.errOf({ =>
            let _ = one.call<Int64>([{ s: String => Int64(s.size) }])
        })
        ok = ok && e3.code == ErrCode.CALL_CONTRACT && e3.site == -1
        let e4 = Q6Acceptance_test.errOf({ =>
            let _ = one.call<Int64>([{ x: Int64 => x.toString() }])
        })
        ok = ok && e4.code == ErrCode.CALL_CONTRACT && e4.site == -1
        let none: ?Int64 = None
        let e5 = Q6Acceptance_test.errOf({ => let _ = one.call<Int64>([none]) })
        ok = ok && e5.code == ErrCode.CALL_CONTRACT && e5.site == -1
        HandleTable.resetForTest()
        @Assert(TCase.hit('T30/entry-marshal-failure-set', ok), true)
    }

    /** 验签一次缓存：同一 `HostCallback` 条目复用同一描述符对象。 */
    @TestCase
    public func t30VerifyResultIsCachedOnEntry(): Unit {
        HandleTable.resetForTest()
        HandleTable.openWindow(128)
        let f: (Int64) -> Int64 = { x => x + 1 }
        let sig = SignatureDescriptor([LocalType.I64], LocalType.I64)
        let m = CallMarshal()
        let id = m.marshalArg(LocalType.HOST_CLOSURE, f, sig: Some(sig))
        let cb = HandleTable.fetchHostCallback(id)
        let a = SignatureVerifier.cached(cb)
        let b = SignatureVerifier.cached(cb)
        var same = false
        match ((a, b)) {
            case (Some(x), Some(y)) => same = refEq(x, y)
            case _ => same = false
        }
        var matches = false
        match (a) {
            case Some(s) => matches = s.params.size == 1 && s.params[0] == LocalType.I64 &&
                s.ret == LocalType.I64
            case None => matches = false
        }
        m.cleanup()
        HandleTable.resetForTest()
        @Assert(TCase.hit('T30/sig-cached-once', same && matches), true)
    }

    /** 禁高阶双重拒绝：前端（参数声明）与验签（T/R 12/13）各自拒绝。 */
    @TestCase
    public func t30HigherOrderIsRejectedTwice(): Unit {
        let c = Q6Acceptance_test.newCompiler()
        var front = false
        try {
            let _ = c.compile('{ f: ((Int64) -> Int64) -> Int64 => 1 }')
        } catch (e: SourceCompileException) {
            front = true
        }
        let bad1 = SignatureDescriptor([LocalType.CLOSURE], LocalType.I64)
        let bad2 = SignatureDescriptor(Array<UInt16>(), LocalType.HOST_CLOSURE)
        let f: (Int64) -> Int64 = { x => x }
        let m = CallMarshal()
        let e1 = Q6Acceptance_test.errOf({ =>
            let _ = m.marshalArg(LocalType.HOST_CLOSURE, f, sig: Some(bad1))
        })
        let e2 = Q6Acceptance_test.errOf({ =>
            let _ = m.marshalArg(LocalType.HOST_CLOSURE, f, sig: Some(bad2))
        })
        let verifyNone = SignatureVerifier.verify(f, bad1).isNone() &&
            SignatureVerifier.verify(f, bad2).isNone()
        HandleTable.resetForTest()
        @Assert(TCase.hit('T30/higher-order-double-reject', front && verifyNone &&
            e1.code == ErrCode.CALL_CONTRACT && e1.site == -1 &&
            e2.code == ErrCode.CALL_CONTRACT && e2.site == -1), true)
    }

    /** 同名冲突（形参 vs user helper）→ 编译错误。 */
    @TestCase
    public func t30HostClosureNameClashIsCompileError(): Unit {
        let c = Q6Acceptance_test.newCompiler()
        c.registerFunction(PredefinedFunction('fn', [LocalType.I64], LocalType.I64, { _ => 1 }))
        var msg = ''
        var kind = ''
        try {
            let _ = c.compile('{ fn: (Int64) -> Int64 => fn(1) }')
        } catch (e: SourceCompileException) {
            msg = e.message
            kind = e.kind
        }
        @Assert(TCase.hit('T30/name-clash-compile-error',
            msg.contains('fn') && msg.contains('冲突')), true)
    }

    /** 已知限制（M2）：验签/分派面只覆盖 0–2 元；>2 元验签 19、直接 H63 分派 99。 */
    /**
     * 三元签名端到端可用（原「>2 元是已知限制」已被反射通道解除）。
     *
     * 旧实现在 `SignatureVerifier.verify` 里只覆盖 0–2 元，`HostCallDispatch` 亦只到 2 元，
     * 故 3 元在入口报 19、直接分派报 99。改用 `FunctionTypeInfo`（验签）+ `apply`（调用）后，
     * 元数不再受限：入口调用成功、直接分派同样成功。
     */
    @TestCase
    public func t30ArityAboveTwoWorks(): Unit {
        let c = Q6Acceptance_test.newCompiler()
        let u = c.compile('{ f: (Int64, Int64, Int64) -> Int64 => f(1, 2, 3) }')
        let f: (Int64, Int64, Int64) -> Int64 = { a, b, cc => a + b + cc }
        let args: Array<Any> = [f]
        let viaEntry = u.call<Int64>(args)
        HandleTable.resetForTest()
        HandleTable.openWindow(128)
        let ctx = JitContext.create(hwBase: HandleTable.windowBaseOf(), hwCap: 128,
            fnId: 0, dbgBase: 0)
        let h = HandleTable.pin(HostCallback(f,
            SignatureDescriptor([LocalType.I64, LocalType.I64, LocalType.I64], LocalType.I64)))
        let direct = invokeHelper(ctx, Int64(HelperId.HOST_CALL_TRAMPOLINE), [h, 1, 2, 3])
        let directOk = ctx.errCode == 0
        JitContext.free(ctx)
        HandleTable.resetForTest()
        @Assert(TCase.hit('T30/arity-above-two-usable',
            viaEntry == 6 && directOk && direct == 6), true)
    }

    // ==================================================================
    // Q6.2 T31 / T60 CALL_HOST 与异常
    // ==================================================================

    /** CALL_HOST 正常调用：值型 / 引用型返回；引用型登记 1 槽（H63 直接对拍）。 */
    @TestCase
    public func t31CallHostValueAndReference(): Unit {
        let c = Q6Acceptance_test.newCompiler()
        let v = c.compile('{ f: (Int64) -> Int64 => f(41) }')
        let valueOk = v.call<Int64>([{ x: Int64 => x + 1 }]) == 42
        let r = c.compile('{ f: () -> String => f() }')
        let refOk = r.call<String>([{ => 'ok-host' }]) == 'ok-host'

        HandleTable.resetForTest()
        HandleTable.openWindow(128)
        let ctx = JitContext.create(hwBase: HandleTable.windowBaseOf(), hwCap: 128,
            fnId: 0, dbgBase: 0)
        let h = HandleTable.pin(HostCallback({ => 'slot' },
            SignatureDescriptor(Array<UInt16>(), LocalType.STRING)))
        let before = HandleTable.windowUsed()
        let cell = invokeHelper(ctx, Int64(HelperId.HOST_CALL_TRAMPOLINE), [h])
        let accounting = ctx.errCode == 0 && HandleTable.windowUsed() == before + 1 &&
            HandleTable.fetchString(cell) == 'slot'
        JitContext.free(ctx)
        HandleTable.resetForTest()
        @Assert(TCase.hit('T31/value-reference-and-window', valueOk && refOk && accounting), true)
    }

    /** 重入（深度 ≥3）：宿主闭包体内再调 JIT，窗口账目恢复、结果正确。 */
    @TestCase
    public func t31ReentrancyDepthThree(): Unit {
        let c = Q6Acceptance_test.newCompiler()
        let leaf = c.compile('{ => 10 }')
        let unitB = c.compile('{ f: () -> Int64 => f() + 10 }')
        let unitC = c.compile('{ f: () -> Int64 => f() + 1 }')
        let inner: () -> Int64 = { => 1 }
        let b: () -> Int64 = { => unitB.call<Int64>([inner]) }
        let outer = c.compile('{ f: () -> Int64 => f() }')
        let base = HandleTable.liveCount()
        let r = outer.call<Int64>([b]) // outer -> unitB -> leaf(10) + 10 = 20 -> +? 见下
        // b 调用 unitB：f() = 1 → 11；outer 原样返回 11。深度 = outer / unitB / inner。
        let ok = r == 11 && HandleTable.liveCount() == base && HandleTable.windowUsed() == 0
        // 再加一层 leaf 调用（确认重入与常量句柄复用）
        let withLeaf: () -> Int64 = { => leaf.call<Int64>([]) + unitB.call<Int64>([inner]) }
        let r2 = outer.call<Int64>([withLeaf])
        let ok2 = r2 == 21 && HandleTable.liveCount() == base
        HandleTable.resetForTest()
        @Assert(TCase.hit('T31/reentrancy-depth3', ok && ok2), true)
    }

    /** 重入内层错误不影响外层错误槽（内层 1 被宿主捕获，外层成功）。 */
    @TestCase
    public func t31InnerErrorDoesNotLeak(): Unit {
        let c = Q6Acceptance_test.newCompiler()
        let bad = c.compile('{ a: Int64 => 10 / (a - a) }')
        let inner: () -> Int64 = { =>
            try {
                let _ = bad.call<Int64>([1])
                0
            } catch (e: JitException) {
                e.code
            }
        }
        let outer = c.compile('{ f: () -> Int64 => f() }')
        let r = outer.call<Int64>([inner])
        HandleTable.resetForTest()
        @Assert(TCase.hit('T31/inner-error-isolated', r == ErrCode.DIV_ZERO), true)
    }

    /** 终止语义：错误点之后的指令不执行（后续除零不会改写 21）。 */
    @TestCase
    public func t31FailFastStopsFollowingInstructions(): Unit {
        let c = Q6Acceptance_test.newCompiler()
        let u = c.compile('{ f: (Int64) -> Int64 => let x = f(1)\n 100 / (x - x) }')
        let e = Q6Acceptance_test.errOf({ =>
            let _ = u.call<Int64>([{ x: Int64 => throw Q6HostBoom('stop') }])
        })
        let ok = e.code == ErrCode.HOST_EXCEPTION && e.site >= 0 &&
            (match (e.cause) { case Some(t) => t.contains('stop'); case None => false })
        HandleTable.resetForTest()
        @Assert(TCase.hit('T31/fail-fast-terminates', ok), true)
    }

    /** T60 三面：CALL_HOST 闭包 / 预定义与包装 / 构造适配器 → 21 + cause。 */
    @TestCase
    public func t60ThreeFacesMapTo21(): Unit {
        let c = Q6Acceptance_test.newCompiler()
        // 第一面：CALL_HOST
        let callHost = c.compile('{ f: () -> Int64 => f() }')
        let e1 = Q6Acceptance_test.errOf({ =>
            let _ = callHost.call<Int64>([{ => throw Q6HostBoom('face-callhost') }])
        })
        // 第二面：预定义函数
        c.registerFunction(PredefinedFunction('q6_boom_helper', Array<UInt16>(),
            LocalType.I64, { _ => throw Q6HostBoom('face-helper') }))
        let helper = c.compile('{ => q6_boom_helper() }')
        let e2 = Q6Acceptance_test.errOf({ => let _ = helper.call<Int64>([]) })
        // 第三面：构造适配器
        c.registerClass(ClassDescriptor(name: 'Q6BoomCtor',
            fields: Array<PublicField>(), methods: Array<PublicMethod>(),
            ctors: [PublicCtor(params: Array<UInt16>(), adapter: { _ =>
                throw Q6HostBoom('face-ctor')
            })]))
        let ctor = c.compile('{ => Q6BoomCtor() }')
        let e3 = Q6Acceptance_test.errOf({ => let _ = ctor.call<Q6BoomCtor>([]) })
        let ok = Q6Acceptance_test.face21(e1, 'face-callhost') &&
            Q6Acceptance_test.face21(e2, 'face-helper') &&
            Q6Acceptance_test.face21(e3, 'face-ctor')
        HandleTable.resetForTest()
        @Assert(TCase.hit('T60/three-faces-21', ok), true)
    }

    private static func face21(e: Q6Err, msg: String): Bool {
        if (e.code != ErrCode.HOST_EXCEPTION || e.site < 0) {
            return false
        }
        match (e.cause) {
            case Some(t) => t.contains(msg)
            case None => false
        }
    }

    /** cause 完整栈：抛出点在前、帧数 ≥ 2。 */
    @TestCase
    public func t60CauseCarriesFullStack(): Unit {
        let c = Q6Acceptance_test.newCompiler()
        let u = c.compile('{ f: () -> Int64 => f() }')
        let e = Q6Acceptance_test.errOf({ =>
            let _ = u.call<Int64>([{ => q6ThrowBoom() }])
        })
        var frames = 0
        var ordered = false
        match (e.cause) {
            case Some(t) =>
                var i = 0
                while (i + 4 <= t.size) {
                    if (t[i..i + 4] == '.cj:') {
                        frames = frames + 1
                    }
                    i = i + 1
                }
                let initAt = Q6Acceptance_test.indexOfText(t, 'Q6HostBoom::init')
                let throwAt = Q6Acceptance_test.indexOfText(t, 'q6ThrowBoom')
                ordered = initAt >= 0 && throwAt > initAt
            case None => ()
        }
        let ok = e.code == ErrCode.HOST_EXCEPTION && frames >= 3 && ordered
        HandleTable.resetForTest()
        @Assert(TCase.hit('T60/cause-full-stack', ok), true)
    }

    /** 子串首次出现位置（-1 = 未找到）；用于栈帧顺序断言。 */
    private static func indexOfText(s: String, sub: String): Int64 {
        let a = s.unsafeBytes()
        let b = sub.unsafeBytes()
        if (b.size == 0 || b.size > a.size) {
            return -1
        }
        var i = 0
        while (i + b.size <= a.size) {
            var j = 0
            var hit = true
            while (j < b.size) {
                if (a[i + j] != b[j]) {
                    hit = false
                    break
                }
                j = j + 1
            }
            if (hit) {
                return i
            }
            i = i + 1
        }
        -1
    }

    /** 并发失败互不串扰：每个线程只看到自己的 cause。 */
    @TestCase
    public func t60ConcurrentFailuresAreIsolated(): Unit {
        let c = Q6Acceptance_test.newCompiler()
        let u = c.compile('{ f: () -> Int64 => f() }')
        let fns = ArrayList<() -> Int64>()
        fns.add({ => throw Q6HostBoom('conc-0') })
        fns.add({ => throw Q6HostBoom('conc-1') })
        fns.add({ => throw Q6HostBoom('conc-2') })
        fns.add({ => throw Q6HostBoom('conc-3') })
        let results = ArrayList<Bool>()
        let rmtx = Mutex()
        let futures = ArrayList<Future<Unit>>()
        var i = 0
        while (i < fns.size) {
            let fn = fns[i]
            let idx = i
            let tag = 'conc-${idx}'
            futures.add(spawn {
                var ok = false
                try {
                    let _ = u.call<Int64>([fn])
                } catch (e: JitException) {
                    let own = match (e.cause) {
                        case Some(t) => t.contains(tag)
                        case None => false
                    }
                    var other = false
                    var j = 0
                    while (j < fns.size) {
                        if (j != idx) {
                            match (e.cause) {
                                case Some(t) =>
                                    if (t.contains('conc-${j}')) {
                                        other = true
                                    }
                                case None => ()
                            }
                        }
                        j = j + 1
                    }
                    ok = e.code == ErrCode.HOST_EXCEPTION && own && !other
                }
                synchronized (rmtx) {
                    results.add(ok)
                }
            })
            i = i + 1
        }
        for (f in futures) {
            f.get()
        }
        var all = results.size == 4
        for (r in results) {
            all = all && r
        }
        HandleTable.resetForTest()
        @Assert(TCase.hit('T60/concurrent-isolation', all), true)
    }

    /** 21 与 99 严格区分：引擎面失败 99 且无 cause（21 才有 cause）。 */
    @TestCase
    public func t60EngineFailureStays99(): Unit {
        HandleTable.resetForTest()
        HandleTable.openWindow(128)
        let ctx = JitContext.create(hwBase: HandleTable.windowBaseOf(), hwCap: 128,
            fnId: 0, dbgBase: 0)
        ctx.site = 777
        // 未验签条目 → 99
        let h1 = HandleTable.pin(HostCallback({ => 1 }))
        let _ = invokeHelper(ctx, Int64(HelperId.HOST_CALL_TRAMPOLINE), [h1])
        let e1 = ctx.errCode
        let c1 = HostFault.causeOf(ctx).isNone()
        ctx.errCode = 0
        // 验签通过但绑定失败（描述符与函数元数不符）→ 99
        let h2 = HandleTable.pin(HostCallback({ x: Int64 => x },
            SignatureDescriptor([LocalType.I64, LocalType.I64], LocalType.I64)))
        let _ = invokeHelper(ctx, Int64(HelperId.HOST_CALL_TRAMPOLINE), [h2, 1, 2])
        let e2 = ctx.errCode
        let c2 = HostFault.causeOf(ctx).isNone()
        // 防御 -1（空实参）→ 99
        ctx.errCode = 0
        let _ = invokeHelper(ctx, Int64(HelperId.HOST_CALL_TRAMPOLINE), Array<Int64>())
        let e3 = ctx.errCode
        JitContext.free(ctx)
        HandleTable.resetForTest()
        @Assert(TCase.hit('T60/99-vs-21-strict',
            e1 == ErrCode.HELPER_PANIC && c1 && e2 == ErrCode.HELPER_PANIC && c2 &&
            e3 == ErrCode.HELPER_PANIC), true)
        @Assert(TCase.hit('T32/defensive-minus1-99', e3 == ErrCode.HELPER_PANIC), true)
    }

    // ==================================================================
    // Q6.3 T32 交互
    // ==================================================================

    /** 单元卸载：活跃调用排空、per-call 宿主闭包句柄释放、卸载后调用 19（site=-1）。 */
    @TestCase
    public func t32UnloadAndHostClosureLifecycle(): Unit {
        let c = Q6Acceptance_test.newCompiler()
        let u = c.compile('{ f: () -> Int64 => f() }')
        let base = HandleTable.liveCount()
        let ok1 = u.call<Int64>([{ => 1 }]) == 1 && HandleTable.liveCount() == base
        // 单元卸载与独立 HostClosure 条目无交互
        let cb = HandleTable.pin(HostCallback({ => 2 },
            SignatureDescriptor(Array<UInt16>(), LocalType.I64)))
        let ok2 = u.unload(0) && HandleTable.isType(cb, TypeToken.HOST_CLOSURE) &&
            u.unload(0) // 幂等
        let e = Q6Acceptance_test.errOf({ => let _ = u.call<Int64>([{ => 1 }]) })
        let ok3 = e.code == ErrCode.CALL_CONTRACT && e.site == -1
        HandleTable.resetForTest()
        @Assert(TCase.hit('T32/unload-hostclosure-drain', ok1 && ok2 && ok3), true)
    }

    /** GC 并发：宿主闭包内大量分配（触发 GC）后返回；对象仍存活、账目归零。 */
    @TestCase
    public func t32GcDuringHostCall(): Unit {
        let c = Q6Acceptance_test.newCompiler()
        let u = c.compile('{ f: () -> Int64 => f() }')
        let boom: () -> Int64 = { =>
            var s = ''
            var i = 0
            while (i < 4000) {
                s = s + 'x'
                i = i + 1
            }
            Int64(s.size)
        }
        let base = HandleTable.liveCount()
        let r = u.call<Int64>([boom])
        let ok = r == 4000 && HandleTable.liveCount() == base && NativeMem.outstanding() == 0
        HandleTable.resetForTest()
        @Assert(TCase.hit('T32/gc-during-host-call', ok), true)
    }

    /** 取消边界：闭包体内 deadline 到期不可抢占；返回后 `interrupt_poll` 才感知 -2。 */
    @TestCase
    public func t32CancelBoundaryIsDeferred(): Unit {
        HandleTable.resetForTest()
        HandleTable.openWindow(128)
        let ctx = JitContext.create(hwBase: HandleTable.windowBaseOf(), hwCap: 128,
            fnId: 0, dbgBase: 0)
        RuntimeEnv.setDeadline(RuntimeEnv.nowNanos() - 1)
        let seen = ArrayList<Bool>()
        let h = HandleTable.pin(HostCallback({ =>
            seen.add(true)
            7
        }, SignatureDescriptor(Array<UInt16>(), LocalType.I64)))
        let r = invokeHelper(ctx, Int64(HelperId.HOST_CALL_TRAMPOLINE), [h])
        let before = ctx.errCode == 0 && r == 7 && seen.size == 1
        let _ = invokeHelper(ctx, Int64(HelperId.INTERRUPT_POLL), Array<Int64>())
        let after = ctx.errCode == ErrCode.INTERRUPT
        RuntimeEnv.clearDeadline()
        JitContext.free(ctx)
        HandleTable.resetForTest()
        @Assert(TCase.hit('T32/cancel-deferred', before && after), true)
    }

    // ==================================================================
    // Q6.4 T34 HostObject
    // ==================================================================

    /** 经预定义函数注入 → 推断局部 → 第二函数转发 → `call<T>` 带回：同一对象。 */
    @TestCase
    public func t34HostObjectRoundtripKeepsIdentity(): Unit {
        let c = Q6Acceptance_test.newCompiler()
        let obj = Q6Entity('inject', 1)
        c.registerFunction(PredefinedFunction('q6_inject', Array<UInt16>(),
            LocalType.HOST_OBJECT, { _ => obj }))
        c.registerFunction(PredefinedFunction('q6_forward',
            [LocalType.HOST_OBJECT], LocalType.HOST_OBJECT, { args => args[0] }))
        let u = c.compile('{ => let x = q6_inject()\n q6_forward(x) }')
        let base = HandleTable.liveCount()
        let back = u.call<Q6Entity>([])
        let ok = refEq(back, obj) && HandleTable.liveCount() == base &&
            NativeMem.outstanding() == 0
        HandleTable.resetForTest()
        @Assert(TCase.hit('T34/identity-roundtrip', ok), true)
    }

    /** null / 型别不符 → 19（site=-1）。 */
    @TestCase
    public func t34NullAndTypeMismatchAre19(): Unit {
        let c = Q6Acceptance_test.newCompiler()
        let u = c.compile('{ e: Q6Entity => 1 }')
        let e1 = Q6Acceptance_test.errOf({ =>
            let _ = u.call<Int64>([Q6Order(1)])
        })
        let none: ?Q6Entity = None
        let e2 = Q6Acceptance_test.errOf({ => let _ = u.call<Int64>([none]) })
        let ok = e1.code == ErrCode.CALL_CONTRACT && e1.site == -1 &&
            e2.code == ErrCode.CALL_CONTRACT && e2.site == -1
        HandleTable.resetForTest()
        @Assert(TCase.hit('T34/null-and-type-mismatch-19', ok), true)
    }

    // ==================================================================
    // Q6.6 T49 逃逸闭包回桥
    // ==================================================================

    /** 提升组：共享计数 / close 归零 / 常量不入组。 */
    @TestCase
    public func t49PromotionGroupAccounting(): Unit {
        HandleTable.resetForTest()
        HandleTable.openWindow(128)
        let ctx = JitContext.create(hwBase: HandleTable.windowBaseOf(), hwCap: 128,
            fnId: 0, dbgBase: 0)
        let id = HandleTable.append(ctx, 'shared', TypeToken.STRING)
        let g = PromotionGroup()
        g.add(id)
        g.add(id)
        let counted = g.size() == 1 && HandleTable.windowUsed() == 0
        g.release(id)
        let still = g.contains(id) && HandleTable.isLiveHandle(id)
        g.release(id)
        let freed = !g.contains(id) && !HandleTable.isLiveHandle(id)
        let c = HandleTable.pinConst('const')
        g.add(c)
        let constKept = !g.contains(c) && HandleTable.isLiveHandle(c)
        HandleTable.releaseConst(c)
        JitContext.free(ctx)
        HandleTable.resetForTest()
        @Assert(TCase.hit('T49/promotion-accounting', counted && still && freed && constKept), true)
    }

    /** 无级联：容器捕获提升后，窗口重置不影响元素可读性与引用身份。 */
    @TestCase
    public func t49NoCascadeForCapturedContainer(): Unit {
        let c = Q6Acceptance_test.newCompiler()
        // 引用身份：捕获的宿主对象（14 形参）经包装器多次调用仍是同一对象。
        let childUnit = c.compile('{ ch: Q6Child => let f = { x: Int64 => ch }\n f }')
        let child = Q6Child('keep')
        let cw = childUnit.callForFn<(Int64) -> Q6Child>([child])
        let a = cw.call<Q6Child>([1])
        let b = cw.call<Q6Child>([2])
        let same = refEq(a, b) && a.city == 'keep'
        cw.unloadFn()
        // 路径 C：外层窗口内新建的 14 局部被捕获（提升后跨窗口仍同一对象）。
        let localUnit = c.compile('{ => let ch = Q6Child("local")\n { x: Int64 => ch } }')
        let lw = localUnit.callForFn<(Int64) -> Q6Child>([])
        let la = lw.call<Q6Child>([1])
        let lb = lw.call<Q6Child>([2])
        let localSame = refEq(la, lb) && la.city == 'local'
        lw.unloadFn()
        // 容器捕获（句柄型形参）：窗口重置后元素仍可读。
        let elemUnit = c.compile('{ l: List<Int64> => let f = { x: Int64 => l[x] }\n f }')
        let lst = ArrayList<Any>()
        lst.add(1)
        lst.add(2)
        lst.add(3)
        let w2 = elemUnit.callForFn<(Int64) -> Int64>([lst])
        let v1 = w2.call<Int64>([1])
        let v2 = w2.call<Int64>([1])
        w2.unloadFn()
        let base = HandleTable.liveCount()
        HandleTable.resetForTest()
        @Assert(TCase.hit('T49/no-cascade', same && localSame && v1 == 2 && v2 == 2), true)
    }

    /** 包装器调用 ≡ 直接 CALL_CLOSURE；close 后调用 → 19；卸载后调用 → 19（site=-1）。 */
    @TestCase
    public func t49WrapperEqualsDirectAndWeakUnload(): Unit {
        let c = Q6Acceptance_test.newCompiler()
        let unit = c.compile('{ => let f = { x: Int64 => x + 1 }\n f }')
        let w = unit.callForFn<(Int64) -> Int64>([])
        let viaWrapper = w.call<Int64>([41])
        let direct = c.compile('{ => let f = { x: Int64 => x + 1 }\n f(41) }')
        let viaDirect = direct.call<Int64>([])
        w.unloadFn()
        let closedErr = Q6Acceptance_test.errOf({ => let _ = w.call<Int64>([1]) })
        let unit2 = c.compile('{ => let f = { x: Int64 => x + 1 }\n f }')
        let w2 = unit2.callForFn<(Int64) -> Int64>([])
        let _ = unit2.unload(0)
        let unloadErr = Q6Acceptance_test.errOf({ => let _ = w2.call<Int64>([1]) })
        w2.unloadFn()
        let ok = viaWrapper == viaDirect && closedErr.code == ErrCode.CALL_CONTRACT &&
            closedErr.site == -1 && unloadErr.code == ErrCode.CALL_CONTRACT &&
            unloadErr.site == -1
        HandleTable.resetForTest()
        @Assert(TCase.hit('T49/wrapper-direct-close-unload', ok), true)
    }

    // ==================================================================
    // Q6.7 T54 构造
    // ==================================================================

    /** 每次求值新实例：两次构造 → 两实例、身份独立；适配器执行次数 == 构造次数。 */
    @TestCase
    public func t54EveryEvaluationCreatesNewInstance(): Unit {
        let c = Q6Acceptance_test.newCompiler()
        let u = c.compile('{ => Q6Entity() }')
        let a = u.call<Q6Entity>([])
        let b = u.call<Q6Entity>([])
        let twice = !refEq(a, b) && Q6Acceptance_test.created.size == 2
        let one = c.compile('{ => let x = Q6Entity("x", 1)\n let y = Q6Entity("y", 2)\n y }')
        let y = one.call<Q6Entity>([])
        let pair = Q6Acceptance_test.created.size == 4 &&
            !refEq(Q6Acceptance_test.created[2], Q6Acceptance_test.created[3]) &&
            refEq(y, Q6Acceptance_test.created[3]) && y.age == 2
        HandleTable.resetForTest()
        @Assert(TCase.hit('T54/new-instance-per-eval', twice && pair), true)
    }

    /** 构造实例全通道：字段 / 方法 / 嵌套构造 / CALL_FUNC 转发（同一对象）。 */
    @TestCase
    public func t54CtorInstanceFlowsAllChannels(): Unit {
        let c = Q6Acceptance_test.newCompiler()
        let f = c.compile('{ => Q6Entity("ann", 3).name }')
        let name = f.call<String>([])
        let m = c.compile('{ => Q6Entity("ann", 3).greet("z") }')
        let greet = m.call<String>([])
        let nested = c.compile('{ => Q6Entity(Q6Child("hz")) }')
        let e = nested.call<Q6Entity>([])
        let chain = e.child.city == 'hz'
        let forward = c.compile('{ => let x = Q6Entity("fwd", 5)\n let g = { y: Q6Entity => y }\n g(x) }')
        let back = forward.call<Q6Entity>([])
        let ok = name == 'ann' && greet == 'hi z' && chain && back.name == 'fwd'
        HandleTable.resetForTest()
        @Assert(TCase.hit('T54/ctor-channels', ok), true)
    }

    /** 窗口账目：每次构造登记 1 槽（直接 user helper 对拍）。 */
    @TestCase
    public func t54CtorRegistersOneSlot(): Unit {
        HandleTable.resetForTest()
        HandleTable.openWindow(128)
        UserHelperTable.resetForTest()
        let ctx = JitContext.create(hwBase: HandleTable.windowBaseOf(), hwCap: 128,
            fnId: 0, dbgBase: 0)
        let made = Q6Entity('slot', 1)
        UserHelperTable.push(0u16, [UserHelperEntry(params: Array<UInt16>(),
            ret: LocalType.HOST_OBJECT, impl: { _ => made })])
        let before = HandleTable.windowUsed()
        let cell = invokeHelper(ctx, Int64(HelperId.USER_BASE), Array<Int64>())
        let one = ctx.errCode == 0 && HandleTable.windowUsed() == before + 1 &&
            HandleTable.tagOf(cell) == TypeToken.HOST_OBJECT &&
            refEq(HandleTable.fetchHostObject(cell), made)
        let before2 = HandleTable.windowUsed()
        let _ = invokeHelper(ctx, Int64(HelperId.USER_BASE), Array<Int64>())
        let two = HandleTable.windowUsed() == before2 + 1
        UserHelperTable.pop()
        JitContext.free(ctx)
        HandleTable.resetForTest()
        @Assert(TCase.hit('T54/ctor-window-accounting', one && two), true)
    }

    /** 重载解析 / 歧义 / 无匹配 → 编译错误；适配器异常 → 21。 */
    @TestCase
    public func t54OverloadAndAdapterFailure(): Unit {
        let c = Q6Acceptance_test.newCompiler()
        c.registerClass(ClassDescriptor(name: 'Q6Ambig', fields: Array<PublicField>(),
            methods: Array<PublicMethod>(),
            ctors: [
                PublicCtor(params: [LocalType.I64], adapter: { _ => Q6Ambig(1) }),
                PublicCtor(params: [LocalType.I64], adapter: { _ => Q6Ambig(2) })
            ]))
        var ambig = ''
        try {
            let _ = c.compile('{ => Q6Ambig(1) }')
        } catch (e: SourceCompileException) {
            ambig = e.message
        }
        var noMatch = ''
        try {
            let _ = c.compile('{ => Q6Entity(true) }')
        } catch (e: SourceCompileException) {
            noMatch = e.message
        }
        c.registerClass(ClassDescriptor(name: 'Q6BoomCtor', fields: Array<PublicField>(),
            methods: Array<PublicMethod>(),
            ctors: [PublicCtor(params: Array<UInt16>(), adapter: { _ =>
                throw Q6HostBoom('ctor-boom')
            })]))
        let boom = c.compile('{ => Q6BoomCtor() }')
        let e = Q6Acceptance_test.errOf({ => let _ = boom.call<Q6BoomCtor>([]) })
        let ok = ambig.contains('歧义') && noMatch.contains('Q6Entity') &&
            e.code == ErrCode.HOST_EXCEPTION && e.site >= 0
        HandleTable.resetForTest()
        @Assert(TCase.hit('T54/overload-ambiguity-adapter-21', ok), true)
    }

    // ==================================================================
    // Q6.7 T57 源入口实参
    // ==================================================================

    /** 实参对象经全通道：字段 / 返回 / HostClosure / CALL_FUNC；同一身份、无泄漏。 */
    @TestCase
    public func t57ArgumentFlowsAllChannels(): Unit {
        let c = Q6Acceptance_test.newCompiler()
        let obj = Q6Entity('bob', 9)
        let field = c.compile('{ e: Q6Entity => e.name }')
        let f1 = field.call<String>([obj]) == 'bob'
        let ret = c.compile('{ e: Q6Entity => e }')
        let f2 = refEq(ret.call<Q6Entity>([obj]), obj)
        let viaHost = c.compile('{ f: (Q6Entity) -> String, e: Q6Entity => f(e) }')
        let host: (Q6Entity) -> String = { e => e.name }
        let f3 = viaHost.call<String>([host, obj]) == 'bob'
        let viaFunc = c.compile(
            '{ e: Q6Entity => let g = { x: Q6Entity => x }\n g(e) }')
        let f4 = refEq(viaFunc.call<Q6Entity>([obj]), obj)
        let base = HandleTable.liveCount()
        let _ = field.call<String>([obj])
        let f5 = HandleTable.liveCount() == base && NativeMem.outstanding() == 0
        HandleTable.resetForTest()
        @Assert(TCase.hit('T57/argument-all-channels', f1 && f2 && f3 && f4 && f5), true)
    }

    /** 子类实例按声明基类通过（opaque 视图）；手工访问器按 `o is C` 支持继承成员。 */
    @TestCase
    public func t57SubclassPassesByBaseClass(): Unit {
        CompileCache.reset()
        HandleTable.resetForTest()
        HostFieldTable.resetForTest()
        let c = Compiler(CompileOptions(DummyDiagnosticsSink()))
        c.registerType<ReflectUser>()
        let admin = ReflectAdmin('root')
        // 反射自动访问器按精确类匹配（std.reflect 限制）：这里只验验签/封送层的 opaque 视图。
        let probe = c.compile('{ r: ReflectUser => 1 }')
        let opaque = probe.call<Int64>([admin]) == 1
        HandleTable.resetForTest()
        // 手工访问器（`accepts = o is Q6Entity`）天然支持子类成员访问。
        let mc = Q6Acceptance_test.newCompiler()
        let sub = Q6SubEntity('sub')
        let field = mc.compile('{ e: Q6Entity => e.name }')
        let inherited = field.call<String>([sub]) == 'sub'
        HandleTable.resetForTest()
        @Assert(TCase.hit('T57/subclass-opaque-view', opaque && inherited), true)
    }

    // ==================================================================
    // Q6.7 T59 HostClosure 签名含 14
    // ==================================================================

    /** R=14 返回：窗口登记 1 槽、同一对象；签名含 12/13 仍拒。 */
    @TestCase
    public func t59HostClosureRet14Accounting(): Unit {
        HandleTable.resetForTest()
        HandleTable.openWindow(128)
        let ctx = JitContext.create(hwBase: HandleTable.windowBaseOf(), hwCap: 128,
            fnId: 0, dbgBase: 0)
        let made = Q6Entity('ret14', 2)
        let h = HandleTable.pin(HostCallback({ => made },
            SignatureDescriptor(Array<UInt16>(), LocalType.HOST_OBJECT)))
        let before = HandleTable.windowUsed()
        let cell = invokeHelper(ctx, Int64(HelperId.HOST_CALL_TRAMPOLINE), [h])
        let one = ctx.errCode == 0 && HandleTable.windowUsed() == before + 1 &&
            HandleTable.tagOf(cell) == TypeToken.HOST_OBJECT &&
            refEq(HandleTable.fetchHostObject(cell), made)
        let bad = SignatureDescriptor(Array<UInt16>(), LocalType.CLOSURE)
        let denied = SignatureVerifier.verify({ => made }, bad).isNone()
        JitContext.free(ctx)
        HandleTable.resetForTest()
        @Assert(TCase.hit('T59/r14-window-and-higher-order-reject', one && denied), true)
    }

    // ==================================================================
    // Q6.5 T35 / T36 成员访问
    // ==================================================================

    /** 糖 ≡ 手写包装：读 / 写结果与宿主可见性一致。 */
    @TestCase
    public func t35SugarEqualsManualWrapper(): Unit {
        let c = Q6Acceptance_test.newCompiler()
        c.registerFunction(PredefinedFunction('q6_manual_name', [LocalType.HOST_OBJECT],
            LocalType.STRING, { args =>
                match (args[0]) { case e: Q6Entity => e.name; case _ => '' }
            }))
        c.registerFunction(PredefinedFunction('q6_manual_set_age',
            [LocalType.HOST_OBJECT, LocalType.I64], LocalType.UNIT, { args => match ((args[0], args[1])) {
                case (e: Q6Entity, n: Int64) => e.age = n
                case _ => ()
            } }))
        let obj = Q6Entity('sugar', 1)
        let sugarRead = c.compile('{ e: Q6Entity => e.name }')
        let manualRead = c.compile('{ e: Q6Entity => q6_manual_name(e) }')
        let readOk = sugarRead.call<String>([obj]) == manualRead.call<String>([obj])
        let sugarWrite = c.compile('{ e: Q6Entity => e.age = 11 }')
        sugarWrite.call<Unit>([obj])
        let a = obj.age
        let manualWrite = c.compile('{ e: Q6Entity => q6_manual_set_age(e, 12) }')
        manualWrite.call<Unit>([obj])
        let b = obj.age
        let writeOk = a == 11 && b == 12
        HandleTable.resetForTest()
        @Assert(TCase.hit('T35/sugar-equals-manual', readOk && writeOk), true)
    }

    /** 字段全类型：值型零登记 / 句柄型 +1 / 14 +1；obj tag≠11 → 8；防御 → 99。 */
    @TestCase
    public func t35FieldTypeMatrixAndDefense(): Unit {
        HandleTable.resetForTest()
        HandleTable.openWindow(128)
        HostFieldTable.resetForTest()
        Q6Acceptance_test.registerFields()
        let ctx = JitContext.create(hwBase: HandleTable.windowBaseOf(), hwCap: 128,
            fnId: 0, dbgBase: 0)
        let obj = Q6Entity('n', 5)
        obj.child = Q6Child('hz')
        let h = HandleTable.pinHostObject(obj)
        let v0 = HandleTable.windowUsed()
        let age = invokeHelper(ctx, Int64(HelperId.HOST_GET_FIELD), [h, 1])
        let valueZero = age == 5 && HandleTable.windowUsed() == v0 && ctx.errCode == 0
        let nameCell = invokeHelper(ctx, Int64(HelperId.HOST_GET_FIELD), [h, 0])
        let handleOne = HandleTable.windowUsed() == v0 + 1 &&
            HandleTable.fetchString(nameCell) == 'n'
        let v1 = HandleTable.windowUsed()
        let childCell = invokeHelper(ctx, Int64(HelperId.HOST_GET_FIELD), [h, 2])
        let objOne = HandleTable.windowUsed() == v1 + 1 &&
            refEq(HandleTable.fetchHostObject(childCell), obj.child)
        // 失败面：tag≠11 → 8；未知 index → 99；let 写 → 19；site 保持调用点
        ctx.errCode = 0
        ctx.site = 4242
        let s = HandleTable.pin('not-object')
        let _ = invokeHelper(ctx, Int64(HelperId.HOST_GET_FIELD), [s, 1])
        let e8 = ctx.errCode == ErrCode.HANDLE_TYPE && ctx.site == 4242
        ctx.errCode = 0
        let _ = invokeHelper(ctx, Int64(HelperId.HOST_GET_FIELD), [h, 99])
        let e99 = ctx.errCode == ErrCode.HELPER_PANIC && ctx.site == 4242
        ctx.errCode = 0
        let _ = invokeHelper(ctx, Int64(HelperId.HOST_SET_FIELD), [h, 3, 9])
        let e19 = ctx.errCode == ErrCode.READONLY && obj.tag == 7 && ctx.site == 4242
        // 值型写：宿主可见、零登记
        ctx.errCode = 0
        let v2 = HandleTable.windowUsed()
        let _ = invokeHelper(ctx, Int64(HelperId.HOST_SET_FIELD), [h, 1, 77])
        let writeOk = obj.age == 77 && HandleTable.windowUsed() == v2 && ctx.errCode == 0
        JitContext.free(ctx)
        HandleTable.resetForTest()
        @Assert(TCase.hit('T35/field-type-matrix-and-defense',
            valueZero && handleOne && objOne && e8 && e99 && e19 && writeOk), true)
    }

    /** 拒绝集：非 HostObject / 未注册类 / 未知成员 / `let` 写 / 签名不符全部编译错误。 */
    @TestCase
    public func t36RejectSetIsCompileErrors(): Unit {
        let c = Q6Acceptance_test.newCompiler()
        // 继承成员未入表：`Child` 描述符里没有 `baseField` → 编译错误
        c.registerClass(ClassDescriptor(name: 'Q6ChildNoBase',
            fields: Array<PublicField>(), methods: Array<PublicMethod>(),
            ctors: Array<PublicCtor>()))
        let kinds = ArrayList<String>()
        let sources = ArrayList<String>()
        sources.add('{ x: Int64 => x.age }')
        sources.add('{ u: Ghost => u.age }')
        sources.add('{ e: Q6Entity => e.ghost }')
        sources.add('{ e: Q6Entity => e.tag = 1 }')
        sources.add('{ e: Q6Entity => e.greet(1) }')
        sources.add('{ c: Q6ChildNoBase => c.baseField }')
        var msgs = ''
        for (src in sources) {
            try {
                let _ = c.compile(src)
                kinds.add('OK')
            } catch (e: SourceCompileException) {
                kinds.add(e.kind)
                msgs = msgs + e.message
            }
        }
        var all = kinds.size == 6
        for (k in kinds) {
            all = all && k != 'OK'
        }
        let named = msgs.contains('Q6Entity') && msgs.contains('ghost') &&
            msgs.contains('Q6ChildNoBase') && msgs.contains('baseField')
        HandleTable.resetForTest()
        @Assert(TCase.hit('T36/reject-set-compile-errors', all && named), true)
    }

    /** 注册表快照：编译后新增类不改变已编译单元的字段 index / 方法 hid。 */
    @TestCase
    public func t36SnapshotDoesNotRetroactivelyChange(): Unit {
        let c = Q6Acceptance_test.newCompiler()
        let f = c.compile('{ e: Q6Entity => e.age }')
        c.registerClass(ClassDescriptor(name: 'Q6Later',
            fields: [PublicField(name: 'age', `type`: LocalType.I64, index: 9u16,
                mutable: true, typeRef: None)],
            methods: Array<PublicMethod>(), ctors: Array<PublicCtor>()))
        let obj = Q6Entity('snap', 33)
        let ok = f.call<Int64>([obj]) == 33
        HandleTable.resetForTest()
        @Assert(TCase.hit('T36/registry-snapshot', ok), true)
    }

    /** `mutable` 双防线：糖编译期拒绝 + 裸 H65 → 19（见 t35 矩阵）；类型链 typeRef。 */
    @TestCase
    public func t36TypeRefChainAndMutableDoubleGuard(): Unit {
        let c = Q6Acceptance_test.newCompiler()
        let chain = c.compile('{ e: Q6Entity => e.child.city }')
        let obj = Q6Entity()
        obj.child = Q6Child('chain')
        let chainOk = chain.call<String>([obj]) == 'chain'
        var sugarReject = ''
        try {
            let _ = c.compile('{ e: Q6Entity => e.tag = 1 }')
        } catch (e: SourceCompileException) {
            sugarReject = e.kind
        }
        HandleTable.resetForTest()
        @Assert(TCase.hit('T36/typeref-chain-mutable-double', chainOk &&
            sugarReject != ''), true)
    }
}

/** 失败码 / site / cause 小载体。 */
protected struct Q6Err {
    public let code: Int64
    public let site: Int64
    public let cause: ?String

    public init(code: Int64, site: Int64, cause: ?String) {
        this.code = code
        this.site = site
        this.cause = cause
    }
}

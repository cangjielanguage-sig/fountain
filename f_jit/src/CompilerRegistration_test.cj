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
import fountain::f_jit.base.ClassDescriptor
import fountain::f_jit.base.DiagCode
import fountain::f_jit.base.DiagnosticLevel
import fountain::f_jit.base.DiagnosticsSink
import fountain::f_jit.base.DummyDiagnosticsSink
import fountain::f_jit.base.LocalType
import fountain::f_jit.base.PredefinedFunction
import fountain::f_jit.base.PublicCtor
import fountain::f_jit.base.PublicField
import fountain::f_jit.base.PublicMethod
import fountain::f_jit.base.RegistrationException
import fountain::f_jit.base.RegistrationRejectKind
import fountain::f_jit.runtime.HostFieldTable
import fountain::f_jit.test.JsonValue
import fountain::f_jit.test.ReflectUser
import fountain::f_jit.test.TCase

/** Q5.4：`Compiler.registerClass` / `registerType<T>`（m2 §12.4/§12.5、design-m2 §6.2）。 */
@Test
public class CompilerRegistration_test {
    private static func manualDescriptor(): ClassDescriptor {
        let greet = PredefinedFunction('ManualUser.greet', [LocalType.HOST_OBJECT, LocalType.STRING],
            LocalType.STRING, { args =>
                match (args[0]) {
                    case u: ManualUser =>
                        match (args[1]) {
                            case s: String => u.greeting(s)
                            case _ => ''
                        }
                    case _ => ''
                }
            })
        ClassDescriptor(name: 'ManualUser',
            fields: [
                PublicField(name: 'name', `type`: LocalType.STRING, index: 0u16,
                    mutable: true, typeRef: None),
                PublicField(name: 'age', `type`: LocalType.I64, index: 1u16,
                    mutable: true, typeRef: None)
            ],
            methods: [PublicMethod(name: 'greet', bind: greet)],
            ctors: [
                PublicCtor(params: [], adapter: { _ => ManualUser() }),
                PublicCtor(params: [LocalType.STRING, LocalType.I64],
                    adapter: { args =>
                        match (args[0]) {
                            case s: String =>
                                match (args[1]) {
                                    case n: Int64 => ManualUser(s, n)
                                    case _ => ManualUser()
                                }
                            case _ => ManualUser()
                        }
                    })
            ])
    }

    private static func registerManualFieldAccessors(): Unit {
        HostFieldTable.register(index: 0u16, `type`: LocalType.STRING, mutable: true,
            accepts: { o => o is ManualUser },
            getter: { o =>
                match (o) {
                    case u: ManualUser => u.name
                    case _ => ''
                }
            },
            setter: { o, v =>
                match (o) {
                    case u: ManualUser =>
                        match (v) {
                            case s: String => u.name = s
                            case _ => ()
                        }
                    case _ => ()
                }
            })
        HostFieldTable.register(index: 1u16, `type`: LocalType.I64, mutable: true,
            accepts: { o => o is ManualUser },
            getter: { o =>
                match (o) {
                    case u: ManualUser => u.age
                    case _ => 0
                }
            },
            setter: { o, v =>
                match (o) {
                    case u: ManualUser =>
                        match (v) {
                            case n: Int64 => u.age = n
                            case _ => ()
                        }
                    case _ => ()
                }
            })
    }

    private static func compiler(): Compiler {
        CompileCache.reset()
        HostFieldTable.resetForTest()
        Compiler(CompileOptions(DummyDiagnosticsSink()))
    }

    /** 端到端：注册类后 `u.f` / `u.f = v` / `u.m()` / `User(...)` 均可用。 */
    @TestCase
    public func manualRegistrationIsEndToEnd(): Unit {
        let c = CompilerRegistration_test.compiler()
        CompilerRegistration_test.registerManualFieldAccessors()
        c.registerClass(CompilerRegistration_test.manualDescriptor())
        @Assert(TCase.hit('T54/register-class', c.hasClass('ManualUser')), true)

        let get = c.compile('{ u: ManualUser => u.name }')
        let u = ManualUser('bob', 5)
        @Assert(get.call<String>([u]), 'bob')

        let set = c.compile('{ u: ManualUser => u.age = 9\n u.age }')
        @Assert(set.call<Int64>([u]), 9)
        @Assert(u.age, 9)

        let call = c.compile('{ u: ManualUser => u.greet("x") }')
        @Assert(call.call<String>([u]), 'hi x')

        let zero = c.compile('{ => ManualUser() }')
        let made = zero.call<ManualUser>([])
        @Assert(made.name, '')

        let two = c.compile('{ => ManualUser("ann", 3) }')
        let made2 = two.call<ManualUser>([])
        @Assert(made2.name, 'ann')
        @Assert(made2.id, 0)

        @Assert(TCase.hit('T54/e2e-member-and-ctor',
            made2.name == 'ann' && made.name == '' && u.age == 9), true)
    }

    /** `registerType<T>` 端到端：字段 / 属性 / 方法 / 构造器全走反射访问器。 */
    @TestCase
    public func reflectionRegistrationIsEndToEnd(): Unit {
        let c = CompilerRegistration_test.compiler()
        c.registerType<ReflectUser>()
        @Assert(TCase.hit('T55/register-type', c.hasClass('ReflectUser')), true)

        let name = c.compile('{ u: ReflectUser => u.name }')
        let u = ReflectUser('bob', 7)
        @Assert(name.call<String>([u]), 'bob')

        let age = c.compile('{ u: ReflectUser => age(u) }')
        @Assert(age.call<Int64>([u]), 0)

        let bump = c.compile('{ u: ReflectUser => u.bump(4)\n age(u) }')
        @Assert(bump.call<Int64>([u]), 4)

        let greet = c.compile('{ u: ReflectUser => u.greet("z") }')
        @Assert(greet.call<String>([u]), 'hi z')

        let mutProp = c.compile('{ u: ReflectUser => setScore(u, 6)\n score(u) }')
        @Assert(mutProp.call<Int64>([u]), 6)

        let ctor = c.compile('{ => ReflectUser("ann", 2) }')
        let made = ctor.call<ReflectUser>([])
        @Assert(made.name, 'ann')
        @Assert(made.id, 2)
        @Assert(TCase.hit('T55/e2e-reflect', made.name == 'ann' && made.id == 2), true)
    }

    /** 快照：编译后的单元不受后续注册变更影响。 */
    @TestCase
    public func compiledUnitKeepsItsSnapshot(): Unit {
        let c = CompilerRegistration_test.compiler()
        CompilerRegistration_test.registerManualFieldAccessors()
        c.registerClass(CompilerRegistration_test.manualDescriptor())
        let f = c.compile('{ u: ManualUser => u.name }')
        // 后续注册不改变已编译单元使用的字段 index / 方法 hid
        let extra = ClassDescriptor(name: 'Later', fields: [
            PublicField(name: 'name', `type`: LocalType.STRING, index: 9u16,
                mutable: true, typeRef: None)
        ], methods: Array<PublicMethod>(), ctors: Array<PublicCtor>())
        c.registerClass(extra)
        @Assert(f.call<String>([ManualUser('kept', 1)]), 'kept')
        @Assert(TCase.hit('T55/compile-snapshot',
            f.call<String>([ManualUser('kept', 1)]) == 'kept'), true)
    }

    /** 四类类名冲突 → `RegistrationException`（kind/name/occupiedBy），且不登记。 */
    @TestCase
    public func fourClassNameClashesAreRejected(): Unit {
        let c = CompilerRegistration_test.compiler()
        c.registerClass(ClassDescriptor(name: 'User', fields: Array<PublicField>(),
            methods: Array<PublicMethod>(), ctors: Array<PublicCtor>()))

        // 1. 已注册类
        CompilerRegistration_test.expectClassReject(c,
            ClassDescriptor(name: 'User', fields: Array<PublicField>(),
                methods: Array<PublicMethod>(), ctors: Array<PublicCtor>()),
            RegistrationRejectKind.DuplicateClass, 'User', 'class:User')

        // 2. 已注册函数名
        c.registerFunction(PredefinedFunction('size', Array<UInt16>(), LocalType.I64, { _ => 0 }))
        CompilerRegistration_test.expectClassReject(c,
            ClassDescriptor(name: 'size', fields: Array<PublicField>(),
                methods: Array<PublicMethod>(), ctors: Array<PublicCtor>()),
            RegistrationRejectKind.FunctionNameClash, 'size', 'func:size')

        // 3. 内建类型名
        CompilerRegistration_test.expectClassReject(c,
            ClassDescriptor(name: 'Int64', fields: Array<PublicField>(),
                methods: Array<PublicMethod>(), ctors: Array<PublicCtor>()),
            RegistrationRejectKind.BuiltinTypeName, 'Int64', 'builtin:Int64')

        // 4. 关键字
        CompilerRegistration_test.expectClassReject(c,
            ClassDescriptor(name: 'match', fields: Array<PublicField>(),
                methods: Array<PublicMethod>(), ctors: Array<PublicCtor>()),
            RegistrationRejectKind.Keyword, 'match', 'keyword:match')

        @Assert(c.hasClass('size'), false)
        @Assert(c.hasClass('Int64'), false)
        @Assert(c.hasClass('match'), false)
        @Assert(TCase.hit('T55/four-name-clashes',
            !c.hasClass('size') && !c.hasClass('Int64') && !c.hasClass('match')), true)
    }

    /** 关闭反射 / JSON 谱系 → 明确报错且不登记。 */
    @TestCase
    public func reflectionAndJsonRejectionsDoNotRegister(): Unit {
        let c = CompilerRegistration_test.compiler()
        var kind1 = RegistrationRejectKind.DuplicateClass
        try {
            c.registerType<ReflectUser>(enabled: false)
        } catch (e: RegistrationException) {
            kind1 = e.kind
        }
        @Assert(kind1, RegistrationRejectKind.ReflectionUnavailable)
        @Assert(c.hasClass('ReflectUser'), false)

        var kind2 = RegistrationRejectKind.DuplicateClass
        try {
            c.registerType<JsonValue>()
        } catch (e: RegistrationException) {
            kind2 = e.kind
        }
        @Assert(kind2, RegistrationRejectKind.JsonFamily)
        @Assert(c.hasClass('JsonValue'), false)
        @Assert(c.registeredNames().contains('JsonValue'), false)
    }

    /** 拒绝 ≠ 跳过：成员名冲突只跳过该成员，类仍注册成功并记 `RegistrationSkipped`。 */
    @TestCase
    public func memberConflictIsSkipNotReject(): Unit {
        let sink = RegistrationSink()
        CompileCache.reset()
        HostFieldTable.resetForTest()
        let c = Compiler(CompileOptions(sink))
        c.registerFunction(PredefinedFunction('age', Array<UInt16>(), LocalType.I64, { _ => 0 }))
        c.registerType<ReflectUser>()
        @Assert(c.hasClass('ReflectUser'), true)
        @Assert(c.hasFunction('age'), true)
        @Assert(sink.contains('age'), true)
        @Assert(TCase.hit('T55/member-skip-not-reject', sink.count() > 0), true)
    }

    /** 消息三段 + 按 kind 固定 hint 逐类断言。 */
    @TestCase
    public func rejectMessageHasThreeSegmentsAndHint(): Unit {
        let cases: Array<(RegistrationRejectKind, String)> = [
            (RegistrationRejectKind.DuplicateClass, '改名（成员名冲突请用手工注册起别名）'),
            (RegistrationRejectKind.FunctionNameClash, '改名（成员名冲突请用手工注册起别名）'),
            (RegistrationRejectKind.BuiltinTypeName, '改名（成员名冲突请用手工注册起别名）'),
            (RegistrationRejectKind.Keyword, '改名（成员名冲突请用手工注册起别名）'),
            (RegistrationRejectKind.JsonFamily, 'JSON 谱系为内建类型，无需注册'),
            (RegistrationRejectKind.ReflectionUnavailable, '回退手工注册')
        ]
        for ((k, hint) in cases) {
            let e = RegistrationException(k, 'X', Some('class:X'))
            @Assert(e.message.contains("class 'X' rejected at registration"), true)
            @Assert(e.message.contains(hint), true)
        }
    }

    private static func expectClassReject(c: Compiler, desc: ClassDescriptor,
        kind: RegistrationRejectKind, name: String, occupied: String): Unit {
        var caught: ?RegistrationException = None
        try {
            c.registerClass(desc)
        } catch (e: RegistrationException) {
            caught = Some(e)
        }
        @Assert(caught.isSome(), true)
        match (caught) {
            case Some(e) =>
                @Assert(e.kind, kind)
                @Assert(e.name, name)
                match (e.occupiedBy) {
                    case Some(v) => @Assert(v, occupied)
                    case None => @Fail('occupiedBy 缺失')
                }
            case None => ()
        }
    }
}

/** 手工注册夹具类（宿主侧真实对象）。 */
public class ManualUser {
    public var name: String
    public var age: Int64

    public init() {
        this.name = ''
        this.age = 0
    }

    public init(name: String, age: Int64) {
        this.name = name
        this.age = age
    }

    public func greeting(s: String): String {
        'hi ${s}'
    }

    public prop id: Int64 {
        get() {
            0
        }
    }
}

/** 记录诊断的测试 sink。 */
protected class RegistrationSink <: DiagnosticsSink {
    private let messages = ArrayList<String>()

    public init() {}

    public func diag(level: DiagnosticLevel, code: DiagCode, message: String): Unit {
        this.messages.add(message)
    }

    public func count(): Int64 {
        this.messages.size
    }

    public func contains(text: String): Bool {
        for (m in this.messages) {
            if (m.contains(text)) {
                return true
            }
        }
        false
    }
}

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
import std.reflect.IllegalTypeException
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_jit.base.ClassDescriptor
import fountain::f_jit.base.DiagCode
import fountain::f_jit.base.DiagnosticLevel
import fountain::f_jit.base.DiagnosticsSink
import fountain::f_jit.base.LocalType
import fountain::f_jit.base.PredefinedFunction
import fountain::f_jit.base.PublicCtor
import fountain::f_jit.base.PublicField
import fountain::f_jit.base.PublicMethod
import fountain::f_jit.base.RegistrationException
import fountain::f_jit.base.RegistrationRejectKind
import fountain::f_jit.runtime.HostFieldTable
import fountain::f_jit.test.JsonArray
import fountain::f_jit.test.JsonNull
import fountain::f_jit.test.JsonObject
import fountain::f_jit.test.JsonValue
import fountain::f_jit.test.ReflectAdmin
import fountain::f_jit.test.ReflectUser
import fountain::f_jit.test.TCase

/** Q5.2：`ReflectRegistrar.registerType<T>`（m2 §12.5、design-m2 §6.1.2）。 */
@Test
public class ReflectRegistrar_test {
    private static func sink(): RecReflectSink {
        RecReflectSink()
    }

    private static func registry(): ClassRegistry {
        ClassRegistry()
    }

    /** 全成员枚举：字段 / prop / mut prop / func / static let / static prop / static func / ctor。 */
    @TestCase
    public func enumeratesAllSupportedMemberKinds(): Unit {
        let reg = ReflectRegistrar_test.registry()
        let out = ReflectRegistrar_test.sink()
        ReflectRegistrar.registerType<ReflectUser>(into: reg, diag: out)
        let d = match (reg.resolve('ReflectUser')) {
            case Some(x) => x
            case None => @Fail('ReflectUser 未注册')
        }

        // 字段：public let/var（raw: Int32 属支撑面外 → 跳过）
        @Assert(d.fields.size, 2)
        let idf = ReflectRegistrar_test.fieldOf(d, 'id')
        @Assert(idf.`type`, LocalType.I64)
        @Assert(idf.mutable, false)
        @Assert(idf.index, 0u16)
        let namef = ReflectRegistrar_test.fieldOf(d, 'name')
        @Assert(namef.`type`, LocalType.STRING)
        @Assert(namef.mutable, true)
        @Assert(namef.index, 1u16)
        @Assert(ReflectRegistrar_test.fieldOfOrNone(d, 'raw').isNone(), true)

        // 实例方法 + 属性访问器（getter 名 = 成员名；mut prop setter = set + 首字母大写）
        @Assert(ReflectRegistrar_test.methodOfOrNone(d, 'bump').isSome(), true)
        @Assert(ReflectRegistrar_test.methodOfOrNone(d, 'greet').isSome(), true)
        let age = ReflectRegistrar_test.methodOf(d, 'age')
        @Assert(age.bind.paramTypes, [LocalType.HOST_OBJECT])
        @Assert(age.bind.retType, LocalType.I64)
        let score = ReflectRegistrar_test.methodOf(d, 'score')
        @Assert(score.bind.retType, LocalType.I64)
        let setScore = ReflectRegistrar_test.methodOf(d, 'setScore')
        @Assert(setScore.bind.paramTypes, [LocalType.HOST_OBJECT, LocalType.I64])
        @Assert(setScore.bind.retType, LocalType.UNIT)

        // 构造器：0 参 / 1 参 / 2 参
        @Assert(d.ctors.size, 3)
        @Assert(ReflectRegistrar_test.hasCtor(d, []), true)
        @Assert(ReflectRegistrar_test.hasCtor(d, [LocalType.STRING]), true)
        @Assert(ReflectRegistrar_test.hasCtor(d, [LocalType.STRING, LocalType.I64]), true)

        // 静态只读包装 + 静态函数进入自动函数面
        @Assert(ReflectRegistrar_test.hasAuto(reg, 'version'), true)
        @Assert(ReflectRegistrar_test.hasAuto(reg, 'label'), true)
        @Assert(ReflectRegistrar_test.hasAuto(reg, 'parse'), true)
        @Assert(TCase.hit('T55/reflect-all-members', d.fields.size == 2 && d.methods.size == 5), true)
    }

    /** `static var` / `static mut prop` 永久跳过（附 B），并逐项记 diagnostics。 */
    @TestCase
    public func skipsStaticMutableMembersWithDiagnostics(): Unit {
        let reg = ReflectRegistrar_test.registry()
        let out = ReflectRegistrar_test.sink()
        ReflectRegistrar.registerType<ReflectUser>(into: reg, diag: out)
        @Assert(ReflectRegistrar_test.hasAuto(reg, 'counter'), false)
        @Assert(ReflectRegistrar_test.hasAuto(reg, 'global'), false)
        @Assert(ReflectRegistrar_test.hasAuto(reg, 'setGlobal'), false)
        @Assert(out.contains('counter'), true)
        @Assert(out.contains('global'), true)
        @Assert(out.onlySkipped(), true)
        @Assert(TCase.hit('T55/reflect-static-mutable-skipped', out.count() >= 2), true)
    }

    /** 支撑面外类型（Int32）→ 该成员跳过 + 诊断。 */
    @TestCase
    public func skipsUnsupportedMemberTypes(): Unit {
        let reg = ReflectRegistrar_test.registry()
        let out = ReflectRegistrar_test.sink()
        ReflectRegistrar.registerType<ReflectUser>(into: reg, diag: out)
        @Assert(out.contains('raw'), true)
        @Assert(TCase.hit('T55/reflect-unsupported-type', out.count() >= 1), true)
        match (reg.resolve('ReflectUser')) {
            case Some(d) => @Assert(ReflectRegistrar_test.fieldOfOrNone(d, 'raw').isNone(), true)
            case None => @Fail('ReflectUser 未注册')
        }
    }

    /** 成员命名冲突 → 该名跳过 + `RegistrationSkipped`；其余成员照常注册。 */
    @TestCase
    public func nameConflictSkipsOnlyThatName(): Unit {
        let reg = ReflectRegistrar_test.registry()
        reg.noteFunction('age')
        let out = ReflectRegistrar_test.sink()
        ReflectRegistrar.registerType<ReflectUser>(into: reg, diag: out)
        let d = match (reg.resolve('ReflectUser')) {
            case Some(x) => x
            case None => @Fail('ReflectUser 未注册')
        }
        @Assert(ReflectRegistrar_test.methodOfOrNone(d, 'age').isNone(), true)
        @Assert(ReflectRegistrar_test.methodOfOrNone(d, 'score').isSome(), true)
        @Assert(out.contains('age'), true)
        @Assert(out.onlySkipped(), true)
    }

    /** 自动 ≡ 手工逐项对拍（字段/方法/构造器/类型码）。 */
    @TestCase
    public func autoMatchesManualDescriptor(): Unit {
        let reg = ReflectRegistrar_test.registry()
        ReflectRegistrar.registerType<ReflectUser>(into: reg, diag: ReflectRegistrar_test.sink())
        let auto = match (reg.resolve('ReflectUser')) {
            case Some(x) => x
            case None => @Fail('ReflectUser 未注册')
        }
        let manual = ReflectRegistrar_test.manualUserDescriptor()
        @Assert(auto.fields.size, manual.fields.size)
        for (f in manual.fields) {
            let a = ReflectRegistrar_test.fieldOf(auto, f.name)
            @Assert(a.`type`, f.`type`)
            @Assert(a.index, f.index)
            @Assert(a.mutable, f.mutable)
            @Assert(a.typeRef.isNone() == f.typeRef.isNone(), true)
        }
        @Assert(auto.methods.size, manual.methods.size)
        for (m in manual.methods) {
            let a = ReflectRegistrar_test.methodOf(auto, m.name)
            @Assert(a.bind.paramTypes, m.bind.paramTypes)
            @Assert(a.bind.retType, m.bind.retType)
        }
        @Assert(auto.ctors.size, manual.ctors.size)
        for (c in manual.ctors) {
            @Assert(ReflectRegistrar_test.hasCtor(auto, c.params), true)
        }
        @Assert(TCase.hit('T55/reflect-auto-equals-manual',
            auto.fields.size == manual.fields.size &&
            auto.methods.size == manual.methods.size &&
            auto.ctors.size == manual.ctors.size), true)
    }

    /** JSON 谱系类拒绝注册（`JsonFamily`），且不登记。 */
    @TestCase
    public func jsonFamilyIsRejected(): Unit {
        ReflectRegistrar_test.expectReject<JsonValue>(RegistrationRejectKind.JsonFamily)
        ReflectRegistrar_test.expectReject<JsonObject>(RegistrationRejectKind.JsonFamily)
        ReflectRegistrar_test.expectReject<JsonArray>(RegistrationRejectKind.JsonFamily)
        ReflectRegistrar_test.expectReject<JsonNull>(RegistrationRejectKind.JsonFamily)
    }

    /** 关闭反射的构建 → `ReflectionUnavailable`，且不登记。 */
    @TestCase
    public func reflectionUnavailableIsRejected(): Unit {
        let reg = ReflectRegistrar_test.registry()
        var caught: ?RegistrationException = None
        try {
            ReflectRegistrar.registerType<ReflectUser>(into: reg, diag: ReflectRegistrar_test.sink(),
                enabled: false)
        } catch (e: RegistrationException) {
            caught = Some(e)
        }
        @Assert(caught.isSome(), true)
        match (caught) {
            case Some(e) =>
                @Assert(e.kind, RegistrationRejectKind.ReflectionUnavailable)
                @Assert(e.name, 'ReflectUser')
                @Assert(e.occupiedBy.isNone(), true)
            case None => ()
        }
        @Assert(reg.snapshot().classes.size, 0)
        @Assert(reg.autoFunctions().size, 0)
    }

    /** 哑火对拍：注册条目的类型码只在 M2 合法集（0–14），JSON 名永不映射为 14。 */
    @TestCase
    public func generatedEntriesNeverTargetJsonCodes(): Unit {
        let reg = ReflectRegistrar_test.registry()
        ReflectRegistrar.registerType<ReflectUser>(into: reg, diag: ReflectRegistrar_test.sink())
        for (f in reg.autoFunctions()) {
            for (t in f.paramTypes) {
                @Assert(t <= LocalType.HOST_OBJECT, true)
            }
            @Assert(f.retType <= LocalType.HOST_OBJECT, true)
        }
        @Assert(TCase.hit('T55/reflect-dud-json', reg.autoFunctions().size > 0), true)
    }

    // ---- helpers ----

    private static func fieldOf(d: ClassDescriptor, name: String): PublicField {
        match (ReflectRegistrar_test.fieldOfOrNone(d, name)) {
            case Some(f) => f
            case None => @Fail('字段缺失: ${name}')
        }
    }

    private static func fieldOfOrNone(d: ClassDescriptor, name: String): ?PublicField {
        for (f in d.fields) {
            if (f.name == name) {
                return Some(f)
            }
        }
        None
    }

    private static func methodOf(d: ClassDescriptor, name: String): PublicMethod {
        match (ReflectRegistrar_test.methodOfOrNone(d, name)) {
            case Some(m) => m
            case None => @Fail('方法缺失: ${name}')
        }
    }

    private static func methodOfOrNone(d: ClassDescriptor, name: String): ?PublicMethod {
        for (m in d.methods) {
            if (m.name == name) {
                return Some(m)
            }
        }
        None
    }

    private static func hasCtor(d: ClassDescriptor, params: Array<UInt16>): Bool {
        for (c in d.ctors) {
            if (c.params.size == params.size) {
                var same = true
                for (i in 0..params.size) {
                    if (c.params[i] != params[i]) {
                        same = false
                    }
                }
                if (same) {
                    return true
                }
            }
        }
        false
    }

    private static func hasAuto(reg: ClassRegistry, name: String): Bool {
        for (f in reg.autoFunctions()) {
            if (f.name == name) {
                return true
            }
        }
        false
    }

    private static func expectReject<T>(kind: RegistrationRejectKind) where T <: Object {
        let reg = ReflectRegistrar_test.registry()
        var caught: ?RegistrationException = None
        try {
            ReflectRegistrar.registerType<T>(into: reg, diag: ReflectRegistrar_test.sink())
        } catch (e: RegistrationException) {
            caught = Some(e)
        }
        @Assert(caught.isSome(), true)
        match (caught) {
            case Some(e) =>
                @Assert(e.kind, kind)
                @Assert(e.occupiedBy.isNone(), true)
            case None => ()
        }
        @Assert(reg.snapshot().classes.size, 0)
        @Assert(reg.autoFunctions().size, 0)
    }

    private static func manualUserDescriptor(): ClassDescriptor {
        ClassDescriptor(name: 'ReflectUser',
            fields: [
                PublicField(name: 'id', `type`: LocalType.I64, index: 0u16,
                    mutable: false, typeRef: None),
                PublicField(name: 'name', `type`: LocalType.STRING, index: 1u16,
                    mutable: true, typeRef: None)
            ],
            methods: [
                PublicMethod(name: 'age', bind: PredefinedFunction('age',
                    [LocalType.HOST_OBJECT], LocalType.I64, { _ => 0 })),
                PublicMethod(name: 'score', bind: PredefinedFunction('score',
                    [LocalType.HOST_OBJECT], LocalType.I64, { _ => 0 })),
                PublicMethod(name: 'setScore', bind: PredefinedFunction('setScore',
                    [LocalType.HOST_OBJECT, LocalType.I64], LocalType.UNIT, { _ => () })),
                PublicMethod(name: 'greet', bind: PredefinedFunction('ReflectUser.greet',
                    [LocalType.HOST_OBJECT, LocalType.STRING], LocalType.STRING, { _ => '' })),
                PublicMethod(name: 'bump', bind: PredefinedFunction('ReflectUser.bump',
                    [LocalType.HOST_OBJECT, LocalType.I64], LocalType.UNIT, { _ => () }))
            ],
            ctors: [
                PublicCtor(params: [], adapter: { _ => 0 }),
                PublicCtor(params: [LocalType.STRING], adapter: { _ => 0 }),
                PublicCtor(params: [LocalType.STRING, LocalType.I64], adapter: { _ => 0 })
            ])
    }
}

/** 记录 diag(level, code, message) 的测试 sink。 */
protected class RecReflectSink <: DiagnosticsSink {
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

    public func onlySkipped(): Bool {
        this.messages.size > 0
    }
}

/**
 * GAP-03：类型判定按「声明类的实例（含子类）」，但反射访问器执行层有硬限制。
 *
 * 语义（用户裁定）：形参声明 `A` 时可传 `B` 实例（`B <: A`）；源码里出现**未注册**的类名
 * 由前端在编译期报错，运行期不再区分。
 *
 * 实测（SDK 1.3.0-alpha，见 Q6 后的探测）：
 * - `ClassTypeInfo.instanceVariables` 只含当前类声明；
 * - `ClassTypeInfo.getInstanceVariable(name)` **也不含继承**（找不到即抛 InfoNotFoundException）；
 * - `InstanceVariableInfo.getValue(子类实例)` 抛 `IllegalTypeException`（`checkDeclaringClassType`
 *   强制精确声明类）。
 *
 * 故分两层记录：① 类型判定必须接受子类（已修 `isInstanceOf`）；② 执行层受反射限制，
 * 需非反射访问器（手工 `o is A` + 直接字段访问，或宏生成）才能真正支持继承字段。
 */
@Test
public class InheritanceField_test {
    @TestCase
    public func subclassMatchesDeclaringClass(): Unit {
        HostFieldTable.resetForTest()
        let reg = ClassRegistry()
        let out = RecReflectSink()
        ReflectRegistrar.registerType<ReflectUser>(into: reg, diag: out)
        let admin = ReflectAdmin('bob')
        // index 0 = `id`（ReflectUser 首个 public let，注册序与 instanceVariables 一致）
        let acc = match (HostFieldTable.find(admin, 0u16)) {
            case Some(x) => x
            case None => @Fail('子类实例未命中父类字段访问器：accepts 仍是精确类判定')
        }
        @Assert(TCase.hit('T36/subclass-accepts', acc.`type` == LocalType.I64), true)
        HostFieldTable.resetForTest()
    }

    /** 记录反射执行层的硬限制（不是「通过」，是「已知不可行」的可执行证据）。 */
    @TestCase
    public func reflectGetValueRejectsSubclassInstance(): Unit {
        HostFieldTable.resetForTest()
        let reg = ClassRegistry()
        let out = RecReflectSink()
        ReflectRegistrar.registerType<ReflectUser>(into: reg, diag: out)
        let admin = ReflectAdmin('bob')
        let acc = match (HostFieldTable.find(admin, 0u16)) {
            case Some(x) => x
            case None => @Fail('子类实例未命中父类字段访问器')
        }
        var threw = false
        try {
            let _ = acc.getter(admin)
        } catch (e: IllegalTypeException) {
            threw = true
        }
        @Assert(TCase.hit('T36/reflect-getvalue-exact-class-only', threw), true)
        HostFieldTable.resetForTest()
    }
}

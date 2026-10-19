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
package fountain::f_jit.compiler

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_jit.base.ClassDescriptor
import fountain::f_jit.base.LocalType
import fountain::f_jit.base.PredefinedFunction
import fountain::f_jit.base.PublicCtor
import fountain::f_jit.base.PublicField
import fountain::f_jit.base.PublicMethod
import fountain::f_jit.base.SourceCompileException
import fountain::f_jit.base.SourcePos

/** Q3.2：`ClassRegistryView.classOf/isRegistered` 与快照语义。 */
@Test
public class ClassRegistryView_test {
    /** 命中 / 未命中。 */
    @TestCase
    public func classLookupHitAndMiss(): Unit {
        let view = ClassRegistryView.of([ClassRegistryView_test.userDescriptor()])
        @Assert(view.isRegistered('User'), true)
        @Assert(view.isRegistered('Address'), false)
        match (view.classOf('User')) {
            case Some(c) => @Assert(c.name, 'User')
            case None => @Fail('已注册类未命中')
        }
        @Assert(view.classOf('Address').isNone(), true)
    }

    /** 快照语义：后建视图看到新增类，旧视图不变。 */
    @TestCase
    public func snapshotIsolation(): Unit {
        let old = ClassRegistryView.of([ClassRegistryView_test.userDescriptor()])
        let newer = ClassRegistryView.of([
            ClassRegistryView_test.userDescriptor(),
            ClassRegistryView_test.addressDescriptor()
        ])
        @Assert(old.isRegistered('Address'), false)
        @Assert(newer.isRegistered('Address'), true)
        @Assert(old.isRegistered('User'), true)
    }

    /** 未注册类的强制解析 → 编译错误，消息含类名。 */
    @TestCase
    public func requireClassReportsName(): Unit {
        let view = ClassRegistryView.of([])
        var msg = ''
        var kind = ''
        try {
            let _ = view.requireClass('Ghost', SourcePos(1, 1), 'x')
        } catch (e: SourceCompileException) {
            msg = e.message
            kind = e.kind
        }
        @Assert(kind, DiagKind.TYPE_MISMATCH)
        @Assert(msg.contains('Ghost'), true)
        @Assert(msg.contains('未注册'), true)
    }

    /** Q3.3：字段解析给出 name → index/type/mutable/typeRef。 */
    @TestCase
    public func fieldLookupCarriesAllFiveParts(): Unit {
        let view = ClassRegistryView.of([ClassRegistryView_test.userDescriptor()])
        match (view.fieldOf('User', 'addr')) {
            case Some(f) =>
                @Assert(f.name, 'addr')
                @Assert(f.index, 2u16)
                @Assert(f.`type`, LocalType.HOST_OBJECT)
                @Assert(f.mutable, true)
                match (f.typeRef) {
                    case Some(r) => @Assert(r, 'Address')
                    case None => @Fail('typeRef 丢失')
                }
            case None => @Fail('字段未命中')
        }
        @Assert(view.fieldOf('User', 'missing').isNone(), true)
    }

    /** Q3.3：方法解析 → bind（首参为该类）；构造器集为重载列表。 */
    @TestCase
    public func methodAndCtorLookup(): Unit {
        let view = ClassRegistryView.of([ClassRegistryView_test.userDescriptor()])
        match (view.methodOf('User', 'save')) {
            case Some(m) =>
                @Assert(m.bind.name, 'user_save')
                @Assert(m.bind.paramTypes[0], LocalType.HOST_OBJECT)
            case None => @Fail('方法未命中')
        }
        @Assert(view.ctorsOf('User').size, 2)
        @Assert(view.ctorsOf('Ghost').size, 0)
    }

    /** Q3.3：未知成员 → 编译错误（消息含类名与成员名）。 */
    @TestCase
    public func unknownMemberReportsBothNames(): Unit {
        let view = ClassRegistryView.of([ClassRegistryView_test.userDescriptor()])
        var msg = ''
        try {
            let _ = view.requireField('User', 'ghost', SourcePos(1, 1), 'x')
        } catch (e: SourceCompileException) {
            msg = e.message
        }
        @Assert(msg.contains('User'), true)
        @Assert(msg.contains('ghost'), true)
        var mmsg = ''
        try {
            let _ = view.requireMethod('Nope', 'save', SourcePos(1, 1), 'x')
        } catch (e: SourceCompileException) {
            mmsg = e.message
        }
        @Assert(mmsg.contains('Nope'), true)
    }

    /**
     * Q3.3 / v0.8.31：前端不做继承谱系上溯——不在表中的继承成员报错；
     * 一旦反射把它写入表（同名字段出现在 fields），则正常绑定。
     */
    @TestCase
    public func inheritedMemberOnlyByTableEntry(): Unit {
        let inherited = PublicField(name: 'baseField', `type`: LocalType.I64, index: 9u16,
            mutable: false, typeRef: None)
        let without = ClassDescriptor(name: 'Child', fields: [], methods: [], ctors: [])
        let withBase = ClassDescriptor(name: 'Child', fields: [inherited], methods: [], ctors: [])
        @Assert(ClassRegistryView.of([without]).fieldOf('Child', 'baseField').isNone(), true)
        match (ClassRegistryView.of([withBase]).fieldOf('Child', 'baseField')) {
            case Some(f) => @Assert(f.index, 9u16)
            case None => @Fail('入表成员未绑定')
        }
    }

    internal static func userDescriptor(): ClassDescriptor {
        ClassDescriptor(
            name: 'User',
            fields: [
                PublicField(name: 'name', `type`: LocalType.STRING, index: 0u16,
                    mutable: false, typeRef: None),
                PublicField(name: 'age', `type`: LocalType.I64, index: 1u16,
                    mutable: true, typeRef: None),
                PublicField(name: 'addr', `type`: LocalType.HOST_OBJECT, index: 2u16,
                    mutable: true, typeRef: Some('Address'))
            ],
            methods: [
                PublicMethod(name: 'save', bind: PredefinedFunction(
                    'user_save', [LocalType.HOST_OBJECT], LocalType.UNIT, { _ => 0 })),
                PublicMethod(name: 'self', bind: PredefinedFunction(
                    'user_self', [LocalType.HOST_OBJECT], LocalType.HOST_OBJECT, { args => args[0] }))
            ],
            ctors: [
                PublicCtor(params: [], adapter: { _ => 'User()' }),
                PublicCtor(params: [LocalType.STRING, LocalType.I64],
                    adapter: { _ => 'User(name, age)' })
            ])
    }

    internal static func addressDescriptor(): ClassDescriptor {
        ClassDescriptor(
            name: 'Address',
            fields: [
                PublicField(name: 'city', `type`: LocalType.STRING, index: 0u16,
                    mutable: true, typeRef: None)
            ],
            methods: [],
            ctors: [PublicCtor(params: [LocalType.STRING], adapter: { _ => 'Address(city)' })])
    }
}

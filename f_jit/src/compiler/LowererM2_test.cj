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

import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_jit.base.DummyDiagnosticsSink
import fountain::f_jit.base.ClassDescriptor
import fountain::f_jit.base.LocalType
import fountain::f_jit.base.PredefinedFunction
import fountain::f_jit.base.PublicCtor
import fountain::f_jit.base.PublicField
import fountain::f_jit.base.PublicMethod
import fountain::f_jit.base.SourceCompileException
import fountain::f_jit.base.Version
import fountain::f_jit.bytecode.FbcReader
import fountain::f_jit.bytecode.FuncFlags
import fountain::f_jit.bytecode.LoadedUnit
import fountain::f_jit.test.TCase

/** Q3.5–Q3.7：M2 降低面（CALL_HOST / 成员访问 / 构造）。 */
@Test
public class LowererM2_test {
    /** CALL_HOST：LOADL fn（栈底）→ 实参左→右 → CALL_HOST 2 → 自动 CHECK_ERR。 */
    @TestCase
    public func callHostInstructionSequence(): Unit {
        let unit = LowererM2_test.compileV2(
            '{ fn: (Int64, Int64) -> Bool, a: Int64, b: Int64 => fn(a, b) }')
        @Assert(LowererM2_test.entryOps(unit), 'LOADL LOADL LOADL SET_SITE CALL_HOST CHECK_ERR RET')
        let d = LowererM2_test.entryDump(unit)
        @Assert(d.contains('LOADL 1'), true)
        @Assert(d.contains('LOADL 2'), true)
        @Assert(d.contains('LOADL 0'), true)
        @Assert(d.contains('CALL_HOST 2'), true)
    }

    /** 单参调用：argc=1，且结果静态类型来自 HostClosure 签名。 */
    @TestCase
    public func callHostOneArgUsesDeclaredReturn(): Unit {
        let unit = LowererM2_test.compileV2('{ fn: (Int64) -> Bool => fn(1) }')
        @Assert(LowererM2_test.entryOps(unit), 'LOADL PUSH_I64 SET_SITE CALL_HOST CHECK_ERR RET')
        @Assert(unit.dir.at(0).retType, LocalType.BOOL)
    }

    /** CALL_HOST 是变更型：函数 flags.bit0 置位（m2 §2）。 */
    @TestCase
    public func callHostMarksMutationFlag(): Unit {
        let unit = LowererM2_test.compileV2('{ fn: (Int64) -> Int64 => fn(1) }')
        let flagged = (unit.dir.at(0).flags & FuncFlags.MUTATION) != 0u16
        @Assert(flagged, true)
        @Assert(TCase.hit('T32/call-host-flags-bit0', flagged), true)
    }

    /** HostClosure 形参/局部与 user helper 同名 → 编译错误。 */
    @TestCase
    public func hostClosureNameClashWithUserHelper(): Unit {
        let snap = LowererM2_test.snap(['fn'])
        var msg = ''
        var kind = ''
        try {
            let _ = LowererM2_test.compileV2('{ fn: (Int64) -> Int64 => fn(1) }', snap)
        } catch (e: SourceCompileException) {
            msg = e.message
            kind = e.kind
        }
        @Assert(kind, DiagKind.SYNTAX_ERROR)
        @Assert(msg.contains('fn'), true)
        @Assert(msg.contains('冲突'), true)
    }

    // ==================================================================
    // Q3.6 成员访问降级
    // ==================================================================

    /** `u.f` 值型 → H64，零登记、结果类型为字段类型。 */
    @TestCase
    public func fieldGetValueType(): Unit {
        let unit = LowererM2_test.compileM2('{ u: User => u.age }')
        @Assert(LowererM2_test.entryOps(unit),
            'LOADL PUSH_I64 SET_SITE CALL_HELPER CHECK_ERR RET')
        @Assert(LowererM2_test.entryDump(unit).contains('CALL_HELPER 64,2'), true)
        @Assert(unit.dir.at(0).retType, LocalType.I64)
    }

    /** `u.f` 句柄型（String）→ H64（条件分配由 H64 负责）。 */
    @TestCase
    public func fieldGetHandleType(): Unit {
        let unit = LowererM2_test.compileM2('{ u: User => u.name }')
        @Assert(unit.dir.at(0).retType, LocalType.STRING)
        @Assert(LowererM2_test.entryDump(unit).contains('CALL_HELPER 64,2'), true)
    }

    /** 14 型字段带 typeRef：`u.addr.city` 两层按各自注册条目解析。 */
    @TestCase
    public func fieldGetChainUsesTypeRef(): Unit {
        let unit = LowererM2_test.compileM2('{ u: User => u.addr.city }')
        @Assert(LowererM2_test.entryOps(unit),
            'LOADL PUSH_I64 SET_SITE CALL_HELPER CHECK_ERR PUSH_I64 SET_SITE ' +
            'CALL_HELPER CHECK_ERR RET')
        @Assert(unit.dir.at(0).retType, LocalType.STRING)
    }

    /** `u.m().f`：方法返回 14 时按接收者类继续解析。 */
    @TestCase
    public func methodResultChain(): Unit {
        let unit = LowererM2_test.compileM2('{ u: User => u.self().age }')
        @Assert(unit.dir.at(0).retType, LocalType.I64)
        let d = LowererM2_test.entryDump(unit)
        @Assert(d.contains('CALL_HELPER 257,1'), true)
        @Assert(d.contains('CALL_HELPER 64,2'), true)
    }

    /** 13 型字段读取后作闭包调用 → CALL_HOST（句柄最后压栈）。 */
    @TestCase
    public func hostClosureFieldCall(): Unit {
        let unit = LowererM2_test.compileM2('{ u: User => u.cb(1) }')
        let ops = LowererM2_test.entryOps(unit)
        @Assert(ops.contains('CALL_HOST'), true)
        @Assert(ops.contains('STOREL'), true)
        @Assert(ops.endsWith('CALL_HOST CHECK_ERR RET'), true)
    }

    /** `u.f = v` → H65；求值顺序 u → v（先 LOADL 接收者，后右值）。 */
    @TestCase
    public func fieldSetOrderAndHelper(): Unit {
        let unit = LowererM2_test.compileM2('{ u: User, a: Int64 => u.age = a + 1 }')
        @Assert(LowererM2_test.entryOps(unit),
            'LOADL PUSH_I64 LOADL PUSH_I64 IADD SET_SITE CALL_HELPER CHECK_ERR POP RET_VOID')
        @Assert(LowererM2_test.entryDump(unit).contains('CALL_HELPER 65,3'), true)
        @Assert((unit.dir.at(0).flags & FuncFlags.MUTATION) != 0u16, true)
    }

    /** `let` 字段写 → 编译错误（mutable=false 主防线）。 */
    @TestCase
    public func letFieldWriteIsRejected(): Unit {
        @Assert(LowererM2_test.compileKindM2('{ u: User => u.name = "x" }'),
            DiagKind.TYPE_MISMATCH)
    }

    /** `u.m(a)` → 预定义包装调用（hid 由方法表 bind 解析）。 */
    @TestCase
    public func methodCallUsesBindHid(): Unit {
        let unit = LowererM2_test.compileM2('{ u: User => u.save("x") }')
        @Assert(LowererM2_test.entryOps(unit),
            'LOADL PUSH_KH SET_SITE CALL_HELPER CHECK_ERR RET_VOID')
        @Assert(LowererM2_test.entryDump(unit).contains('CALL_HELPER 256,2'), true)
    }

    /** 方法签名实参不符 → 编译错误。 */
    @TestCase
    public func methodArgMismatchIsRejected(): Unit {
        @Assert(LowererM2_test.compileKindM2('{ u: User => u.save(1) }'),
            DiagKind.TYPE_MISMATCH)
    }

    /** 非 HostObject 用点号 / 未注册类 / 未知成员 → 编译错误（含类名/成员名）。 */
    @TestCase
    public func memberAccessRejectSet(): Unit {
        @Assert(LowererM2_test.compileKindM2('{ x: Int64 => x.age }'),
            DiagKind.TYPE_MISMATCH)
        @Assert(LowererM2_test.compileKindM2('{ u: Ghost => u.age }'),
            DiagKind.BAD_PARAMETER_LIST)
        var msg = ''
        try {
            let _ = LowererM2_test.compileM2('{ u: User => u.ghost }')
        } catch (e: SourceCompileException) {
            msg = e.message
        }
        @Assert(msg.contains('User'), true)
        @Assert(msg.contains('ghost'), true)
    }

    /** 继承成员：不在注册表条目 → 编译错误；入表则正常绑定（前端不上溯）。 */
    @TestCase
    public func inheritedMemberOnlyByTable(): Unit {
        @Assert(LowererM2_test.compileKindM2('{ c: Child => c.baseField }'),
            DiagKind.TYPE_MISMATCH)
        let unit = LowererM2_test.compileM2('{ c: Child => c.baseField }',
            LowererM2_test.m2Snap(), LowererM2_test.classSnap(true))
        @Assert(LowererM2_test.entryDump(unit).contains('CALL_HELPER 64,2'), true)
    }

    // ==================================================================
    // Q3.7 构造降低
    // ==================================================================

    /** `User()` → 实参求值 + CALL_HELPER <ctor-hid> + 自动 CHECK_ERR（零新指令/helper）。 */
    @TestCase
    public func zeroArgCtorLowersToUserHelper(): Unit {
        let unit = LowererM2_test.compileM2('{ => User() }')
        @Assert(LowererM2_test.entryOps(unit), 'SET_SITE CALL_HELPER CHECK_ERR RET')
        @Assert(LowererM2_test.entryDump(unit).contains('CALL_HELPER 258,0'), true)
        @Assert(unit.dir.at(0).retType, LocalType.HOST_OBJECT)
    }

    /** 实参左→右 + 静态重载选择（`User("a", 1)`）。 */
    @TestCase
    public func ctorArgsAreLeftToRight(): Unit {
        let unit = LowererM2_test.compileM2('{ => User("a", 1) }')
        @Assert(LowererM2_test.entryOps(unit),
            'PUSH_KH PUSH_I64 SET_SITE CALL_HELPER CHECK_ERR RET')
        @Assert(LowererM2_test.entryDump(unit).contains('CALL_HELPER 258,2'), true)
    }

    /** 同一单元内不同构造器物化为不同 user helper slot。 */
    @TestCase
    public func overloadsGetDistinctHelperSlots(): Unit {
        let unit = LowererM2_test.compileM2('{ => let a = User()\n User("a") }')
        let d = LowererM2_test.entryDump(unit)
        @Assert(d.contains('CALL_HELPER 258,0'), true)
        @Assert(d.contains('CALL_HELPER 259,1'), true)
    }

    /** 嵌套构造：`User(Addr("x"))` 的 14 实参合法。 */
    @TestCase
    public func nestedCtorIsLegal(): Unit {
        let unit = LowererM2_test.compileM2('{ => User(Address("x")) }')
        let d = LowererM2_test.entryDump(unit)
        @Assert(d.contains('CALL_HELPER 258,1'), true)
        @Assert(d.contains('CALL_HELPER 259,1'), true)
    }

    /** 无匹配实参 → 编译错误；重载歧义 → 编译错误。 */
    @TestCase
    public func ctorOverloadFailures(): Unit {
        @Assert(LowererM2_test.compileKindM2('{ => User(true) }'), DiagKind.TYPE_MISMATCH)
        var msg = ''
        try {
            let _ = LowererM2_test.compileM2('{ => Ambig(1) }')
        } catch (e: SourceCompileException) {
            msg = e.message
        }
        @Assert(msg.contains('歧义'), true)
    }

    /** 构造结果携带类知识，可直接进入成员链。 */
    @TestCase
    public func ctorResultEntersMemberChain(): Unit {
        let unit = LowererM2_test.compileM2('{ => User("a").save("x") }')
        let d = LowererM2_test.entryDump(unit)
        @Assert(d.contains('CALL_HELPER 258,1'), true)
        @Assert(d.contains('CALL_HELPER 256,2'), true)
    }

    /** JSON 谱系构造写法 → 编译错误（内建码，无注册构造器）。 */
    @TestCase
    public func jsonFamilyConstructionIsRejected(): Unit {
        var msg = ''
        try {
            let _ = LowererM2_test.compileM2('{ => JsonObject() }')
        } catch (e: SourceCompileException) {
            msg = e.message
        }
        @Assert(msg.contains('JSON'), true)
    }

    // ==================================================================
    // 工具
    // ==================================================================

    internal static func compileV2(src: String): LoadedUnit {
        LowererM2_test.compileV2(src, PredefinedSnapshot.empty())
    }

    internal static func entryBytes(unit: LoadedUnit): Array<UInt8> {
        let e = unit.entry()
        let n = Int64(e.codeLen)
        let out = Array<UInt8>(n, repeat: 0u8)
        var i: Int64 = 0
        while (i < n) {
            out[i] = unit.code[Int64(e.codeOff) + i]
            i = i + 1
        }
        out
    }

    internal static func entryOps(unit: LoadedUnit): String {
        CodeDump.ops(LowererM2_test.entryBytes(unit))
    }

    internal static func entryDump(unit: LoadedUnit): String {
        CodeDump.dump(LowererM2_test.entryBytes(unit))
    }

    internal static func compileV2(src: String, snap: PredefinedSnapshot): LoadedUnit {
        let sc = SourceCompiler(snap, DummyDiagnosticsSink(), verMajor: Version.M2_MAJOR)
        FbcReader.load(sc.compile(src).raw)
    }

    internal static func compileM2(src: String): LoadedUnit {
        LowererM2_test.compileM2(src, LowererM2_test.m2Snap(),
            LowererM2_test.classSnap(false))
    }

    internal static func compileM2(src: String, snap: PredefinedSnapshot,
        classes: ClassRegistrySnapshot): LoadedUnit {
        let sc = SourceCompiler(snap, DummyDiagnosticsSink(), verMajor: Version.M2_MAJOR,
            classes: classes)
        FbcReader.load(sc.compile(src).raw)
    }

    internal static func compileKindM2(src: String): String {
        var got = ''
        try {
            let _ = LowererM2_test.compileM2(src)
        } catch (e: SourceCompileException) {
            got = e.kind
        }
        got
    }

    /** 方法表 bind 对应的预定义函数注册快照（slot 0 = user_save，1 = user_self）。 */
    internal static func m2Snap(): PredefinedSnapshot {
        PredefinedSnapshot(
            ['user_save', 'user_self'],
            [[LocalType.HOST_OBJECT, LocalType.STRING], [LocalType.HOST_OBJECT]],
            [LocalType.UNIT, LocalType.HOST_OBJECT])
    }

    internal static func classSnap(withInherited: Bool): ClassRegistrySnapshot {
        let user = ClassDescriptor(
            name: 'User',
            fields: [
                PublicField(name: 'name', `type`: LocalType.STRING, index: 0u16,
                    mutable: false, typeRef: None),
                PublicField(name: 'age', `type`: LocalType.I64, index: 1u16,
                    mutable: true, typeRef: None),
                PublicField(name: 'addr', `type`: LocalType.HOST_OBJECT, index: 2u16,
                    mutable: true, typeRef: Some('Address')),
                PublicField(name: 'cb', `type`: LocalType.HOST_CLOSURE, index: 3u16,
                    mutable: false, typeRef: None)
            ],
            methods: [
                PublicMethod(name: 'save', bind: PredefinedFunction(
                    'user_save', [LocalType.HOST_OBJECT, LocalType.STRING], LocalType.UNIT,
                    { _ => 0 })),
                // M2.2：返回 14 的方法必须声明 retName，链式 `u.self().age` 才可静态解析
                PublicMethod(name: 'self', bind: PredefinedFunction(
                    'user_self', [LocalType.HOST_OBJECT], LocalType.HOST_OBJECT,
                    { args => args[0] }, retName: 'User'))
            ],
            ctors: [
                PublicCtor(params: Array<UInt16>(), adapter: { _ => 'User()' }),
                PublicCtor(params: [LocalType.STRING], adapter: { _ => 'User(name)' }),
                PublicCtor(params: [LocalType.STRING, LocalType.I64],
                    adapter: { _ => 'User(name, age)' }),
                PublicCtor(params: [LocalType.HOST_OBJECT], adapter: { _ => 'User(addr)' })
            ])
        let addr = ClassDescriptor(
            name: 'Address',
            fields: [
                PublicField(name: 'city', `type`: LocalType.STRING, index: 0u16,
                    mutable: true, typeRef: None)
            ],
            methods: [],
            ctors: [PublicCtor(params: [LocalType.STRING], adapter: { _ => 'Address(city)' })])
        let ambig = ClassDescriptor(
            name: 'Ambig',
            fields: [],
            methods: [],
            ctors: [
                PublicCtor(params: [LocalType.I64], adapter: { _ => 'Ambig(i)' }),
                PublicCtor(params: [LocalType.I64], adapter: { _ => 'Ambig(j)' })
            ])
        let childFields = if (withInherited) {
            [PublicField(name: 'baseField', `type`: LocalType.I64, index: 0u16,
                mutable: false, typeRef: None)]
        } else {
            Array<PublicField>()
        }
        let child = ClassDescriptor(name: 'Child', fields: childFields, methods: [], ctors: [])
        ClassRegistrySnapshot([user, addr, child, ambig])
    }

    internal static func compileKindV2(src: String, snap: PredefinedSnapshot): String {
        var got = ''
        try {
            let _ = LowererM2_test.compileV2(src, snap)
        } catch (e: SourceCompileException) {
            got = e.kind
        }
        got
    }

    internal static func snap(names: Array<String>): PredefinedSnapshot {
        var params = ArrayList<Array<UInt16>>()
        var rets = ArrayList<UInt16>()
        for (_ in names) {
            params.add([LocalType.I64])
            rets.add(LocalType.I64)
        }
        PredefinedSnapshot(names, params.toArray(), rets.toArray())
    }
}

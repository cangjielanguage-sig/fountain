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
package fountain::f_jit.base

import std.unittest.*
import std.unittest.testmacro.*

/**
 * Q1.4 / Q1.5 注册协议值类型的失败用例（先写红）。
 *
 * 权威 = `doc/jit-bytecode-m2.md` §12.2 / §12.4 / §15 与 `design-m2.md` §2.2：
 * - `PublicField(name, type, index, mutable, typeRef)`，`type` ∈ LocalType 0–14；
 * - `PublicMethod(name, bind: PredefinedFunction)`，bind 首参固定为该类（LocalType 14）；
 * - `PublicCtor(params, adapter)`，`adapter: (Array<Any>) -> Any`；
 * - `ClassDescriptor(name, fields, methods, ctors)`，快照语义（构造后不与入参数组共享）。
 */
@Test
public class PublicField_test {
    /** 构造保真：五个字段与入参逐项一致；`mutable=false` 即 `let`。 */
    @TestCase
    public func fieldsRoundTrip(): Unit {
        let f = PublicField(
            name: 'age',
            `type`: LocalType.I64,
            index: 3u16,
            mutable: true,
            typeRef: None)
        @Assert(f.name, 'age')
        @Assert(f.`type`, LocalType.I64)
        @Assert(f.index, 3u16)
        @Assert(f.mutable, true)
        @Assert(f.typeRef.isNone(), true)

        let ro = PublicField(
            name: 'name',
            `type`: LocalType.STRING,
            index: 0u16,
            mutable: false,
            typeRef: None)
        @Assert(ro.mutable, false)
        @Assert(ro.`type`, LocalType.STRING)
    }

    /** 14 型字段携带 typeRef（链式解析 `u.a.b`）；非 14 型不消费 typeRef。 */
    @TestCase
    public func hostObjectFieldCarriesTypeRef(): Unit {
        let f = PublicField(
            name: 'address',
            `type`: LocalType.HOST_OBJECT,
            index: 7u16,
            mutable: false,
            typeRef: Some('Address'))
        @Assert(f.`type`, 14u16)
        @Assert(f.typeRef.isSome(), true)
        match (f.typeRef) {
            case Some(v) => @Assert(v, 'Address')
            case None => @Fail('typeRef 丢失')
        }
    }

    /** `type` 合法集 0–14；15（M3 预留）及更大值拒绝。 */
    @TestCase
    public func typeLegalSetIsZeroToFourteen(): Unit {
        for (code in 0..15) {
            let f = PublicField(
                name: 'f${code}',
                `type`: UInt16(code),
                index: UInt16(code),
                mutable: true,
                typeRef: None)
            @Assert(f.`type`, UInt16(code))
        }
        for (code in [15u16, 16u16, 19u16, 20u16, 255u16]) {
            var rejected = false
            try {
                let _ = PublicField(
                    name: 'bad',
                    `type`: code,
                    index: 0u16,
                    mutable: true,
                    typeRef: None)
            } catch (ex: JitException) {
                @Assert(ex.code, ErrCode.CALL_CONTRACT)
                rejected = true
            }
            @Assert(rejected, true)
        }
    }
}

@Test
public class PublicMethod_test {
    /** 方法项保真；bind 首参为该类（LocalType 14），签名 `(C, T...) -> R`。 */
    @TestCase
    public func methodBindKeepsReceiverFirst(): Unit {
        let bind = PredefinedFunction(
            'save',
            [LocalType.HOST_OBJECT, LocalType.STRING],
            LocalType.UNIT,
            { args => args.size })
        let m = PublicMethod(name: 'save', bind: bind)
        @Assert(m.name, 'save')
        @Assert(m.bind.paramTypes.size, 2)
        @Assert(m.bind.paramTypes[0], LocalType.HOST_OBJECT)
        @Assert(m.bind.paramTypes[1], LocalType.STRING)
        @Assert(m.bind.retType, LocalType.UNIT)
        // adapter 可调用（包装模式：首参 = 宿主对象）
        let r = m.bind.impl([1, 'v1']) as Int64
        @Assert(r, 2)
    }
}

@Test
public class PublicCtor_test {
    /** 构造器项保真：params 序列 + adapter 可调用并返回实例值。 */
    @TestCase
    public func ctorParamsAndAdapterAreCallable(): Unit {
        let c = PublicCtor(
            params: [LocalType.I64, LocalType.STRING],
            adapter: { args => args.size })
        @Assert(c.params.size, 2)
        @Assert(c.params[0], LocalType.I64)
        @Assert(c.params[1], LocalType.STRING)
        let r = c.adapter([7, 'u']) as Int64
        @Assert(r, 2)
    }

    /** 14 型形参（嵌套构造 `User(Addr(…))`）与 13 型形参合法；12（内部闭包）不在构造器参数面。 */
    @TestCase
    public func ctorParamLegalSetFollowsPredefinedSurface(): Unit {
        for (code in [LocalType.HOST_OBJECT, LocalType.HOST_CLOSURE]) {
            let ok = PublicCtor(params: [code], adapter: { args => args.size })
            @Assert(ok.params[0], code)
        }

        var rejected = false
        try {
            let _ = PublicCtor(params: [LocalType.CLOSURE], adapter: { args => args.size })
        } catch (ex: JitException) {
            @Assert(ex.code, ErrCode.CALL_CONTRACT)
            rejected = true
        }
        @Assert(rejected, true)
    }
}

@Test
public class ClassDescriptor_test {
    private func field(name: String, idx: UInt16): PublicField {
        PublicField(name: name, `type`: LocalType.I64, index: idx, mutable: true, typeRef: None)
    }

    private func method(name: String): PublicMethod {
        PublicMethod(
            name: name,
            bind: PredefinedFunction(name, [LocalType.HOST_OBJECT], LocalType.UNIT, { _ => () }))
    }

    private func ctor(params: Array<UInt16>): PublicCtor {
        PublicCtor(params: params, adapter: { args => args.size })
    }

    /** 四类条目可组合成完整描述符：name / fields / methods / ctors 构造保真。 */
    @TestCase
    public func descriptorRoundTrip(): Unit {
        let d = ClassDescriptor(
            name: 'User',
            fields: [field('id', 0u16), field('age', 1u16)],
            methods: [method('save')],
            ctors: [ctor([LocalType.I64])])
        @Assert(d.name, 'User')
        @Assert(d.fields.size, 2)
        @Assert(d.fields[0].name, 'id')
        @Assert(d.fields[1].name, 'age')
        @Assert(d.methods.size, 1)
        @Assert(d.methods[0].name, 'save')
        @Assert(d.methods[0].bind.paramTypes[0], LocalType.HOST_OBJECT)
        @Assert(d.ctors.size, 1)
        @Assert(d.ctors[0].params[0], LocalType.I64)
    }

    /** 空表合法：无字段/方法/构造器的类描述符仍可构造。 */
    @TestCase
    public func emptyTablesAreAllowed(): Unit {
        let d = ClassDescriptor(name: 'Empty', fields: [], methods: [], ctors: [])
        @Assert(d.name, 'Empty')
        @Assert(d.fields.size, 0)
        @Assert(d.methods.size, 0)
        @Assert(d.ctors.size, 0)
    }

    /** 多构造器重载：同 name 多条 ctor 按登记顺序保真保留（解析由前端 ctorsOf 承担）。 */
    @TestCase
    public func multipleCtorOverloadsArePreserved(): Unit {
        let d = ClassDescriptor(
            name: 'User',
            fields: [],
            methods: [],
            ctors: [ctor([LocalType.I64]), ctor([LocalType.I64, LocalType.STRING])])
        @Assert(d.ctors.size, 2)
        @Assert(d.ctors[0].params.size, 1)
        @Assert(d.ctors[1].params.size, 2)
        @Assert(d.ctors[1].params[1], LocalType.STRING)
    }

    /** 快照语义：构造时拷贝数组，入参数组后续变更不影响描述符；两个描述符互不共享。 */
    @TestCase
    public func arraysAreNotSharedWithCallers(): Unit {
        let fs: Array<PublicField> = [field('id', 0u16)]
        let d1 = ClassDescriptor(name: 'A', fields: fs, methods: [], ctors: [])
        let d2 = ClassDescriptor(name: 'B', fields: fs, methods: [], ctors: [])
        fs[0] = field('changed', 9u16)
        @Assert(d1.fields[0].name, 'id')
        @Assert(d2.fields[0].name, 'id')

        d1.fields[0] = field('mutated', 3u16)
        @Assert(d2.fields[0].name, 'id')
    }
}

/**
 * GAP-05 乙：13 型字段可携带函数签名。
 *
 * `u.cb(a)` 的签名既不能从字段名推，也不能从 `typeRef`（只有类名）推；手工注册显式给出后，
 * `CALL_HOST` 才能带 `sigId` 走精确签名。自动注册（`std.reflect`）给不出函数类型 ⇒ 留空 ⇒
 * 该字段调用退回旧的 `argc` 分派。
 */
@Test
public class PublicFieldSignature_test {
    @TestCase
    public func hostClosureFieldCarriesSignature(): Unit {
        let f = PublicField(name: 'cb', `type`: LocalType.HOST_CLOSURE, index: 2u16,
            mutable: false, typeRef: None,
            sigParams: [LocalType.HOST_OBJECT], sigParamNames: ['User'],
            sigRet: LocalType.HOST_OBJECT, sigRetName: 'Order')
        @Assert(f.hasSignature(), true)
        @Assert(f.sigParams.size, 1)
        @Assert(f.sigParams[0], LocalType.HOST_OBJECT)
        @Assert(f.sigParamNames[0], 'User')
        @Assert(f.sigRet, LocalType.HOST_OBJECT)
        @Assert(f.sigRetName, 'Order')
    }

    /** 非 13 型字段不带签名（`hasSignature` 为假），既有注册面不受影响。 */
    @TestCase
    public func valueFieldHasNoSignature(): Unit {
        let f = PublicField(name: 'id', `type`: LocalType.I64, index: 0u16, mutable: false,
            typeRef: None)
        @Assert(f.hasSignature(), false)
        @Assert(f.sigParams.size, 0)
    }

    /** 类名个数与形参个数不符 ⇒ 注册期拒绝（避免半截签名流到运行期）。 */
    @TestCase
    public func mismatchedSignatureIsRejected(): Unit {
        var rejected = false
        try {
            let _ = PublicField(name: 'cb', `type`: LocalType.HOST_CLOSURE, index: 0u16,
                mutable: false, typeRef: None,
                sigParams: [LocalType.HOST_OBJECT, LocalType.I64],
                sigParamNames: ['User'],
                sigRet: LocalType.I64, sigRetName: '')
        } catch (e: JitException) {
            rejected = true
        }
        @Assert(rejected, true)
    }
}

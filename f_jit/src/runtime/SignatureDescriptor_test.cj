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
import fountain::f_jit.base.LocalType
import fountain::f_jit.test.ReflectAdmin
import fountain::f_jit.test.ReflectUser

/**
 * Q4.1 `SignatureDescriptor` 的值语义与合法集（m2 §1/§4）。
 *
 * 编码 = **参数字节码序列 + 返回字节码**，原样保存 LocalType；`validate` 的合法集
 * = `0–8、10、11、14`（12 内部闭包、13 宿主闭包在 T/R 一律拒绝——禁高阶）。
 */
@Test
public class SignatureDescriptor_test {
    /** 构造保真：参数序列与返回码原样保存（编码断言）。 */
    @TestCase
    public func encodingPreservesCodes(): Unit {
        let s = SignatureDescriptor([LocalType.I64, LocalType.STRING, LocalType.HOST_OBJECT],
            LocalType.STRING)
        @Assert(s.params.size, 3)
        @Assert(s.params[0], LocalType.I64)
        @Assert(s.params[1], LocalType.STRING)
        @Assert(s.params[2], LocalType.HOST_OBJECT)
        @Assert(s.ret, LocalType.STRING)
    }

    /** 0 参签名合法（`() -> R`）；空参数表不共享（防御性拷贝/独立值）。 */
    @TestCase
    public func emptyParamsIsLegal(): Unit {
        let s = SignatureDescriptor(Array<UInt16>(), LocalType.UNIT)
        @Assert(s.params.size, 0)
        @Assert(s.validate(), true)
    }

    /** T/R ∈ 0–8、10、11、14 全部合法（9=Regex 不在签名合法集，§3）。 */
    @TestCase
    public func legalCodeSet(): Unit {
        let legal = [0u16, 1u16, 2u16, 3u16, 4u16, 5u16, 6u16, 7u16, 8u16, 10u16, 11u16, 14u16]
        for (t in legal) {
            let p = SignatureDescriptor([t], LocalType.I64)
            @Assert(p.validate(), true)
            let r = SignatureDescriptor([LocalType.I64], t)
            @Assert(r.validate(), true)
        }
    }

    /** 12（内部闭包）/13（宿主闭包）作形参 ⇒ 非法（禁高阶）。 */
    @TestCase
    public func closureCodesRejectedAsParam(): Unit {
        for (t in [LocalType.CLOSURE, LocalType.HOST_CLOSURE]) {
            let s = SignatureDescriptor([t], LocalType.I64)
            @Assert(s.validate(), false)
        }
    }

    /** 12/13 作返回 ⇒ 非法（禁高阶：R 取具体非函数类型）。 */
    @TestCase
    public func closureCodesRejectedAsReturn(): Unit {
        for (t in [LocalType.CLOSURE, LocalType.HOST_CLOSURE]) {
            let s = SignatureDescriptor([LocalType.I64], t)
            @Assert(s.validate(), false)
        }
    }

    /** 14 合法（宿主对象可作 T/R，v0.8.19 §16.4）。 */
    @TestCase
    public func hostObjectIsLegal(): Unit {
        @Assert(SignatureDescriptor([LocalType.HOST_OBJECT], LocalType.HOST_OBJECT).validate(),
            true)
    }

    /** 越界码（15 起 / 255）⇒ 非法。 */
    @TestCase
    public func outOfRangeCodesRejected(): Unit {
        // 16–19 自 M3 起是合法分量（JSON 内建码，零注册）；15（Any 盒）与 20+ 仍拒。
        for (t in [15u16, 20u16, 255u16]) {
            @Assert(SignatureDescriptor([t], LocalType.I64).validate(), false)
            @Assert(SignatureDescriptor([LocalType.I64], t).validate(), false)
        }
    }
}

/**
 * GAP-04 / GAP-05：反射验签（`FunctionTypeInfo`）。
 *
 * 旧路径 `verify` 只覆盖 0–2 元且 14 位置不校验具体类；这里用真实函数值的类型信息逐位比对，
 * 元数不受限、14 按类名逐字相等。
 */
@Test
public class ReflectiveVerify_test {
    /** 14 位置按类名比对：声明 `ReflectUser` 时，`ReflectAdmin` 的函数必须被拒。 */
    @TestCase
    public func checksConcreteClassName(): Unit {
        let declared = SignatureDescriptor([LocalType.HOST_OBJECT], LocalType.I64,
            paramNames: ['ReflectUser'])
        let ok: (ReflectUser) -> Int64 = { u => u.id }
        @Assert(SignatureVerifier.verifyReflective(ok, declared).isSome(), true)
        let bad: (ReflectAdmin) -> Int64 = { u => u.id }
        @Assert(SignatureVerifier.verifyReflective(bad, declared).isNone(), true)
    }

    /** 元数不受限：3 元通过（旧路径 `>2 ⇒ None`）。 */
    @TestCase
    public func supportsArityAboveTwo(): Unit {
        let declared = SignatureDescriptor([LocalType.I64, LocalType.I64, LocalType.I64],
            LocalType.I64)
        let f: (Int64, Int64, Int64) -> Int64 = { a, b, c => a + b + c }
        @Assert(SignatureVerifier.verifyReflective(f, declared).isSome(), true)
        let g: (Int64, Int64) -> Int64 = { a, b => a + b }
        @Assert(SignatureVerifier.verifyReflective(g, declared).isNone(), true)
    }

    /** 返回类型不符必须拒绝；值型逐位比对。 */
    @TestCase
    public func checksReturnAndValueParams(): Unit {
        let declared = SignatureDescriptor([LocalType.I64], LocalType.STRING)
        let ok: (Int64) -> String = { n => 'v${n}' }
        @Assert(SignatureVerifier.verifyReflective(ok, declared).isSome(), true)
        let bad: (Int64) -> Int64 = { n => n }
        @Assert(SignatureVerifier.verifyReflective(bad, declared).isNone(), true)
        let wrongParam: (String) -> String = { s => s }
        @Assert(SignatureVerifier.verifyReflective(wrongParam, declared).isNone(), true)
    }

    /** 非函数值不得通过。 */
    @TestCase
    public func rejectsNonFunctionValue(): Unit {
        let declared = SignatureDescriptor([LocalType.I64], LocalType.I64)
        @Assert(SignatureVerifier.verifyReflective(42, declared).isNone(), true)
    }
}

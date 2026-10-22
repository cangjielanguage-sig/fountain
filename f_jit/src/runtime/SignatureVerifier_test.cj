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

/** 验签用的宿主类（14 的返回协变断言）。 */
public class SigMarker {
    public let v: Int64
    public init(v: Int64) {
        this.v = v
    }
}

/**
 * Q4.2/Q4.3 验签与条目缓存（m2 §4）。
 *
 * 语义 = **一次 `is (T1..Tn) -> R`**：非函数值 / 参数个数 / 逐参 / 返回任一不符 ⇒ None；
 * 合法 ⇒ 描述符。`SignatureVerifier` 纯静态（无实例、无构造、无状态）。
 *
 * 实现注：Cangjie 的函数类型判定必须在**静态类型**上书写，而描述符是运行期数据；本实现
 * 以「元数判定 + 逐位逆变判定 + 返回协变判定」的合取等价实现同一判定（函数类型的子类型
 * 关系按位独立：`(U1..Un)->S <: (T1..Tn)->R` ⇔ ∀i. Ti <: Ui ∧ S <: R），判定结果与
 * 单次 `is (T1..Tn)->R` 逐位一致。
 */
@Test
public class SignatureVerifier_test {
    /** 合法内建值型签名 ⇒ Some（描述符原样产出）。 */
    @TestCase
    public func valueSignatureAccepted(): Unit {
        let v: Any = { x: Int64 => x > 0 }
        let d = SignatureDescriptor([LocalType.I64], LocalType.BOOL)
        match (SignatureVerifier.verify(v, d)) {
            case Some(s) =>
                @Assert(s.params.size, 1)
                @Assert(s.params[0], LocalType.I64)
                @Assert(s.ret, LocalType.BOOL)
            case None => @Fail('合法签名不应被拒')
        }
    }

    /** 非函数值 ⇒ None（19 的上游信号）。 */
    @TestCase
    public func nonFunctionRejected(): Unit {
        let v: Any = 42
        @Assert(SignatureVerifier.verify(v, SignatureDescriptor([LocalType.I64],
            LocalType.I64)).isNone(), true)
    }

    /** 参数个数不符 ⇒ None（单次判定一并覆盖）。 */
    @TestCase
    public func arityMismatchRejected(): Unit {
        let v: Any = { x: Int64 => x }
        @Assert(SignatureVerifier.verify(v, SignatureDescriptor([LocalType.I64, LocalType.I64],
            LocalType.I64)).isNone(), true)
        let v2: Any = { x: Int64, y: Int64 => x + y }
        @Assert(SignatureVerifier.verify(v2,
            SignatureDescriptor([LocalType.I64], LocalType.I64)).isNone(), true)
        @Assert(SignatureVerifier.verify(v2, SignatureDescriptor(Array<UInt16>(),
            LocalType.I64)).isNone(), true)
    }

    /** 逐参逆变：形参不是声明类型的超类型 ⇒ None。 */
    @TestCase
    public func paramContravarianceRejected(): Unit {
        let v: Any = { s: String => Int64(s.size) }
        @Assert(SignatureVerifier.verify(v, SignatureDescriptor([LocalType.I64],
            LocalType.I64)).isNone(), true)
    }

    /** 逐参逆变：更宽的形参（`Any`）可接受 ⇒ Some。 */
    @TestCase
    public func widerParamAccepted(): Unit {
        let v: Any = { x: Any => 1 }
        @Assert(SignatureVerifier.verify(v, SignatureDescriptor([LocalType.I64],
            LocalType.I64)).isSome(), true)
    }

    /** 返回协变：返回类型不符 ⇒ None。 */
    @TestCase
    public func returnMismatchRejected(): Unit {
        let v: Any = { x: Int64 => x }
        @Assert(SignatureVerifier.verify(v, SignatureDescriptor([LocalType.I64],
            LocalType.BOOL)).isNone(), true)
    }

    /** 禁高阶：返回函数值 ⇒ None（R 取具体非函数类型承接）。 */
    @TestCase
    public func higherOrderRejected(): Unit {
        let v: Any = { x: Int64 => { y: Int64 => y + x } }
        @Assert(SignatureVerifier.verify(v, SignatureDescriptor([LocalType.I64],
            LocalType.I64)).isNone(), true)
    }

    /** 0 参 / 2 参合法。 */
    @TestCase
    public func arityZeroAndTwoAccepted(): Unit {
        let z: Any = { => 7 }
        @Assert(SignatureVerifier.verify(z, SignatureDescriptor(Array<UInt16>(),
            LocalType.I64)).isSome(), true)
        let two: Any = { a: Int64, b: String => a + Int64(b.size) }
        @Assert(SignatureVerifier.verify(two, SignatureDescriptor([LocalType.I64,
            LocalType.STRING], LocalType.I64)).isSome(), true)
    }

    /** 14 形参（不透明宿主对象）合法：`(Object) -> Int64` 通过。 */
    @TestCase
    public func hostObjectParamAccepted(): Unit {
        let v: Any = { o: Object => 1 }
        @Assert(SignatureVerifier.verify(v, SignatureDescriptor([LocalType.HOST_OBJECT],
            LocalType.I64)).isSome(), true)
    }

    /** 14 返回：宿主类实例（Object 子类）通过（返回协变）。 */
    @TestCase
    public func hostObjectReturnAccepted(): Unit {
        let v: Any = { x: Int64 => SigMarker(x) }
        @Assert(SignatureVerifier.verify(v, SignatureDescriptor([LocalType.I64],
            LocalType.HOST_OBJECT)).isSome(), true)
    }

    /** 12/13 出现在 T/R ⇒ 描述符非法 ⇒ None（与 validate 同一判定）。 */
    @TestCase
    public func closureCodesRejected(): Unit {
        let v: Any = { x: Int64 => x }
        @Assert(SignatureVerifier.verify(v, SignatureDescriptor([LocalType.CLOSURE],
            LocalType.I64)).isNone(), true)
        @Assert(SignatureVerifier.verify(v, SignatureDescriptor([LocalType.I64],
            LocalType.HOST_CLOSURE)).isNone(), true)
    }

    /** `SignatureVerifier` 无实例/无构造（纯静态）：编译期可见面只有静态成员。 */
    @TestCase
    public func verifierHasNoState(): Unit {
        // 只验证静态入口可用且同一输入可重复调用（无状态）。
        let v: Any = { x: Int64 => x > 0 }
        let d = SignatureDescriptor([LocalType.I64], LocalType.BOOL)
        @Assert(SignatureVerifier.verify(v, d).isSome(), true)
        @Assert(SignatureVerifier.verify(v, d).isSome(), true)
    }
}

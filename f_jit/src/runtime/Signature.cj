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

import std.collection.ArrayList
import std.collection.HashMap
import std.math.numeric.Decimal
import std.time.DateTime
import std.reflect.FunctionTypeInfo
import std.reflect.TypeInfo
import fountain::f_jit.base.LocalType
import fountain::f_jit.base.TypeNames
import fountain::f_jit.bytecode.ConstMapKey

/**
 * 宿主闭包签名编码（m2 §1/§4）—— 参数 LocalType 序列 + 返回 LocalType。
 *
 * **值语义**：两个只读字段，构造后不变；`validate` 判定 T/R 是否落在 M2 的合法集
 * `0–8、10、11、14`（12 内部闭包、13 宿主闭包在签名里一律不合法——禁高阶）。
 */
public class SignatureDescriptor {
    public let params: Array<UInt16>
    public let ret: UInt16

    /**
     * 14 位置的**具体类名**（与 `params` 等长，非 14 位置为空串）。
     *
     * 只带码无法区分 `(User) -> R` 与 `(Order) -> R`；反射验签按 `TypeInfo.name` 逐字比对，
     * 类名为空表示「只比大类」。
     */
    public let paramNames: Array<String>

    /** 返回值的具体类名（`ret != 14` 时为空串）。 */
    public let retName: String

    public init(params: Array<UInt16>, ret: UInt16, paramNames!: Array<String> = Array<String>(),
        retName!: String = '') {
        var copy = Array<UInt16>(params.size, repeat: 0)
        var i = 0
        while (i < params.size) {
            copy[i] = params[i]
            i = i + 1
        }
        this.params = copy
        this.ret = ret
        this.paramNames = paramNames.clone()
        this.retName = retName
    }

    /**
     * 签名合法性：每个 T 与 R 都必须是具体非函数类型。
     *
     * 合法集 = `0–8`（值型 + 句柄型 + Regex）、`10`、`11`（List/Map）、`14`（HostObject）；
     * `12`（内部闭包）/`13`（宿主闭包）以及 `15+` 一律拒绝。
     */
    public func validate(): Bool {
        for (t in this.params) {
            if (!SignatureDescriptor.isLegalCode(t)) {
                return false
            }
        }
        SignatureDescriptor.isLegalCode(this.ret)
    }

    /** `T/R` 合法码（m2 §3「T/R ∈ 0–8/10–11 与 14」）。 */
    public static func isLegalCode(t: UInt16): Bool {
        (t <= LocalType.RANGE) || (t == LocalType.LIST) || (t == LocalType.MAP) ||
            (t == LocalType.HOST_OBJECT)
    }
}

/**
 * 宿主闭包验签（m2 §4）—— **纯静态工具类**：只有静态函数，无实例、无构造、无状态。
 *
 * 判定面 = 一次 `is (T1..Tn) -> R` 的等价实现：
 *
 * ```
 * 函数类型子类型：(U1..Un) -> S <: (T1..Tn) -> R  ⇔  ∀i. Ti <: Ui  ∧  S <: R
 * ```
 *
 * 参数侧逐位独立（逆变）、返回侧独立（协变），故「元数 ∥ 逐位 ∥ 返回」的合取与单次整体判定
 * 结果逐位一致；实现之所以不能直接写 `is (T1..Tn) -> R`，是因为 Cangjie 的 `is` 要求静态
 * 类型，而 `T/R` 是运行期描述符数据。
 *
 * **支持面**：元数 0–2（M2 宿主回调的交付面）。>2 ⇒ `None`（由 Marshal 转 19），
 * 不进入「验签通过、转发才失败」的分裂状态。
 */
public class SignatureVerifier {
    private init() {}

    /**
     * **反射验签**：用 `FunctionTypeInfo` 取出宿主函数值的真实签名，与声明逐位比对。
     *
     * 与 `verify` 的区别：`verify` 走「元数 ∥ 逐位 ∥ 返回」的分步核对且只覆盖 0–2 元、
     * 14 位置不校验具体类；本函数元数不受限，且 14 位置按类名逐字比对（GAP-04/05）。
     */
    public static func verifyReflective(value: Any, declared: SignatureDescriptor):
        ?SignatureDescriptor {
        if (!declared.validate()) {
            return None
        }
        let ti = try {
            FunctionTypeInfo.of(value)
        } catch (e: Exception) {
            return None
        }
        let n = declared.params.size
        if (Int64(ti.parameters.size) != n) {
            return None
        }
        // 类名数组允许缺省（老调用点只给码）：缺省时视为「所有位置只比大类」。
        let namesAligned = declared.paramNames.size == n
        var i = 0
        while (i < n) {
            let p = ti.parameters[i]
            let expected = if (namesAligned) {
                declared.paramNames[i]
            } else {
                ''
            }
            if (!SignatureVerifier.componentMatches(p.name, declared.params[i], expected, false)) {
                return None
            }
            i = i + 1
        }
        if (!SignatureVerifier.componentMatches(ti.returnType.name, declared.ret,
            declared.retName, true)) {
            return None
        }
        declared
    }

    /**
     * 单个分量比对：码必须一致；14 位置若给了类名，则要求类型名逐字相等。
     *
     * **返回位置另按协变放行 `Nothing`**：`{ x => throw ... }` 的推断返回类型是 `Nothing`，
     * 它是任意 `R` 的子类型，赋给 `(Int64) -> Int64` 合法。逐字比对若不放行，会把
     * 「总是抛异常的宿主函数」误判为签名不符（T31/T60 的既有用例正是这种写法）。
     */
    private static func componentMatches(actualName: String, code: UInt16,
        expectedName: String, isReturn: Bool): Bool {
        if (isReturn && actualName == 'Nothing') {
            return true
        }
        if (TypeNames.codeOf(actualName) != code) {
            return false
        }
        if (code == LocalType.HOST_OBJECT && expectedName != '') {
            return actualName == expectedName
        }
        true
    }

    /** 验签：不符 ⇒ `None`；通过 ⇒ 新描述符（由调用方写入句柄条目）。 */
    public static func verify(value: Any, declared: SignatureDescriptor): ?SignatureDescriptor {
        if (!declared.validate()) {
            return None
        }
        let n = declared.params.size
        if (!SignatureVerifier.arityMatches(value, n)) {
            return None
        }
        var i = 0
        while (i < n) {
            if (!SignatureVerifier.paramMatches(value, n, i, declared.params[i])) {
                return None
            }
            i = i + 1
        }
        if (!SignatureVerifier.returnMatches(value, n, declared.ret)) {
            return None
        }
        SignatureDescriptor(declared.params, declared.ret)
    }

    /** 元数判定（同时排除非函数值）：`is (Nothing×n) -> Any` 只约束「是 n 元函数」。 */
    private static func arityMatches(value: Any, n: Int64): Bool {
        match (n) {
            case 0 => value is () -> Any
            case 1 => value is (Nothing) -> Any
            case 2 => value is (Nothing, Nothing) -> Any
            case _ => false
        }
    }

    /** 第 i 位的逆变判定；其余位用 `Nothing`（bottom）消去约束。 */
    private static func paramMatches(value: Any, n: Int64, i: Int64, code: UInt16): Bool {
        if (code == LocalType.HOST_OBJECT) {
            // 14 的具体类由声明侧静态知识承载（不进描述符），此处只要求是函数值。
            return true
        }
        if (n == 1) {
            return SignatureVerifier.pos1(value, code)
        }
        if (i == 0) {
            return SignatureVerifier.pos2a(value, code)
        }
        SignatureVerifier.pos2b(value, code)
    }

    /** 返回协变判定（R 取具体非函数类型，天然拒绝高阶返回）。 */
    private static func returnMatches(value: Any, n: Int64, ret: UInt16): Bool {
        if (n == 0) {
            return SignatureVerifier.ret0(value, ret)
        }
        if (n == 1) {
            return SignatureVerifier.ret1(value, ret)
        }
        SignatureVerifier.ret2(value, ret)
    }

    // ---- 逐位判定表（元数 × 位置 × LocalType）----

    private static func pos1(value: Any, code: UInt16): Bool {
        match (code) {
            case 0u16 => value is (Int64) -> Any
            case 1u16 => value is (Float64) -> Any
            case 2u16 => value is (Bool) -> Any
            case 3u16 => value is (Unit) -> Any
            case 4u16 => value is (String) -> Any
            case 5u16 => value is (Decimal) -> Any
            case 6u16 => value is (DateTime) -> Any
            case 7u16 => value is (Duration) -> Any
            case 8u16 => value is (Range<Int64>) -> Any
            case 10u16 => value is (ArrayList<Any>) -> Any
            case 11u16 => value is (HashMap<ConstMapKey, Any>) -> Any
            case 14u16 => true
            case _ => false
        }
    }

    private static func pos2a(value: Any, code: UInt16): Bool {
        match (code) {
            case 0u16 => value is (Int64, Nothing) -> Any
            case 1u16 => value is (Float64, Nothing) -> Any
            case 2u16 => value is (Bool, Nothing) -> Any
            case 3u16 => value is (Unit, Nothing) -> Any
            case 4u16 => value is (String, Nothing) -> Any
            case 5u16 => value is (Decimal, Nothing) -> Any
            case 6u16 => value is (DateTime, Nothing) -> Any
            case 7u16 => value is (Duration, Nothing) -> Any
            case 8u16 => value is (Range<Int64>, Nothing) -> Any
            case 10u16 => value is (ArrayList<Any>, Nothing) -> Any
            case 11u16 => value is (HashMap<ConstMapKey, Any>, Nothing) -> Any
            case 14u16 => true
            case _ => false
        }
    }

    private static func pos2b(value: Any, code: UInt16): Bool {
        match (code) {
            case 0u16 => value is (Nothing, Int64) -> Any
            case 1u16 => value is (Nothing, Float64) -> Any
            case 2u16 => value is (Nothing, Bool) -> Any
            case 3u16 => value is (Nothing, Unit) -> Any
            case 4u16 => value is (Nothing, String) -> Any
            case 5u16 => value is (Nothing, Decimal) -> Any
            case 6u16 => value is (Nothing, DateTime) -> Any
            case 7u16 => value is (Nothing, Duration) -> Any
            case 8u16 => value is (Nothing, Range<Int64>) -> Any
            case 10u16 => value is (Nothing, ArrayList<Any>) -> Any
            case 11u16 => value is (Nothing, HashMap<ConstMapKey, Any>) -> Any
            case 14u16 => true
            case _ => false
        }
    }

    private static func ret0(value: Any, ret: UInt16): Bool {
        match (ret) {
            case 0u16 => value is () -> Int64
            case 1u16 => value is () -> Float64
            case 2u16 => value is () -> Bool
            case 3u16 => value is () -> Unit
            case 4u16 => value is () -> String
            case 5u16 => value is () -> Decimal
            case 6u16 => value is () -> DateTime
            case 7u16 => value is () -> Duration
            case 8u16 => value is () -> Range<Int64>
            case 10u16 => value is () -> ArrayList<Any>
            case 11u16 => value is () -> HashMap<ConstMapKey, Any>
            case 14u16 => value is () -> Object
            case _ => false
        }
    }

    private static func ret1(value: Any, ret: UInt16): Bool {
        match (ret) {
            case 0u16 => value is (Nothing) -> Int64
            case 1u16 => value is (Nothing) -> Float64
            case 2u16 => value is (Nothing) -> Bool
            case 3u16 => value is (Nothing) -> Unit
            case 4u16 => value is (Nothing) -> String
            case 5u16 => value is (Nothing) -> Decimal
            case 6u16 => value is (Nothing) -> DateTime
            case 7u16 => value is (Nothing) -> Duration
            case 8u16 => value is (Nothing) -> Range<Int64>
            case 10u16 => value is (Nothing) -> ArrayList<Any>
            case 11u16 => value is (Nothing) -> HashMap<ConstMapKey, Any>
            case 14u16 => value is (Nothing) -> Object
            case _ => false
        }
    }

    private static func ret2(value: Any, ret: UInt16): Bool {
        match (ret) {
            case 0u16 => value is (Nothing, Nothing) -> Int64
            case 1u16 => value is (Nothing, Nothing) -> Float64
            case 2u16 => value is (Nothing, Nothing) -> Bool
            case 3u16 => value is (Nothing, Nothing) -> Unit
            case 4u16 => value is (Nothing, Nothing) -> String
            case 5u16 => value is (Nothing, Nothing) -> Decimal
            case 6u16 => value is (Nothing, Nothing) -> DateTime
            case 7u16 => value is (Nothing, Nothing) -> Duration
            case 8u16 => value is (Nothing, Nothing) -> Range<Int64>
            case 10u16 => value is (Nothing, Nothing) -> ArrayList<Any>
            case 11u16 => value is (Nothing, Nothing) -> HashMap<ConstMapKey, Any>
            case 14u16 => value is (Nothing, Nothing) -> Object
            case _ => false
        }
    }

    /**
     * 条目级缓存：**只收条目**（不做对象 → 条目定位）。
     *
     * 缓存 = 条目字段的存在性：已验签 ⇒ `Some(sig)`；未验签 ⇒ `None`。
     */
    public static func cached(entry: HostCallback): ?SignatureDescriptor {
        entry.sig
    }
}

/**
 * 宿主闭包句柄载荷（m2 §1）—— 句柄表 tag=10 的条目内容。
 *
 * `fn` 是宿主仓颉闭包对象本身（GC 托管）；条目持**强引用** ⇒ 调用期间对象不可能死亡。
 * `sig` 同时充当验签结果的缓存：`None` = 尚未验签。
 */
public class HostCallback {
    public let fn: Any
    public let sig: ?SignatureDescriptor

    public init(fn: Any, sig: SignatureDescriptor) {
        this.fn = fn
        this.sig = Some(sig)
    }

    public init(fn: Any) {
        this.fn = fn
        this.sig = None
    }
}

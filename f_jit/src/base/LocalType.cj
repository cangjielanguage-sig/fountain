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

/**
 * 局部类型码（LocalType）常量命名空间 —— design-m1 §2.3.8、plan-m1 S1.1。
 *
 * **为什么是「类 + `static const」而不是顶层常量或 `enum`**（design D3）：LocalType 是要**编码进
 * `.fbc`** 的数值（§11.7 局部类型表每槽 1 字节），序列化与分派需要**确定的数值码**，而仓颉 `enum`
 * 的构造器不携带数值；250+ 个顶层常量则会污染导入空间。同一族还有 `TypeToken` / `ErrCode` /
 * `HelperId` / `Version` / `ConstKind` / `FbcFlags` / `OpInfo.CAT_*`。
 *
 * 数值权威 = `doc/jit-bytecode-m1.md` §11.7：
 *
 * ```
 * 0=Int64  1=Float64  2=Bool  3=Unit  4=String  5=Decimal  6=DateTime  7=Duration
 * 8=Range  9=Regex  10=List  11=Map  12=Closure  13=HostClosure  14=HostObject
 * 15=Any  16–19=JSON（M3 登记）；20–255 保留（加载器拒绝）
 * ```
 */
public class LocalType {
    /** 值型槽：槽内存原始 cell（§11.7「值型（0–3）槽存原始 cell」）。 */
    public static const I64: UInt16 = 0u16
    public static const F64: UInt16 = 1u16
    public static const BOOL: UInt16 = 2u16
    public static const UNIT: UInt16 = 3u16

    /** 句柄型槽（不可变值）：槽内存句柄 ID（§11.7「句柄型（4–14）槽存句柄 ID（0=null）」）。 */
    public static const STRING: UInt16 = 4u16
    public static const DECIMAL: UInt16 = 5u16
    public static const DATETIME: UInt16 = 6u16
    public static const DURATION: UInt16 = 7u16
    public static const RANGE: UInt16 = 8u16
    public static const REGEX: UInt16 = 9u16

    /** 容器句柄：v0.7 起可作参数槽，v0.18 起全槽位合法（§11.7）。 */
    public static const LIST: UInt16 = 10u16
    public static const MAP: UInt16 = 11u16

    /** 内部闭包值句柄（v0.10，§8.6；仅限 `CALL_FUNC` 链内返回，不可经 `call<T>` 逃逸）。 */
    public static const CLOSURE: UInt16 = 12u16

    /** 宿主闭包句柄（M2 §1；句柄型，空安全同 M1 句柄型）。 */
    public static const HOST_CLOSURE: UInt16 = 13u16

    /** 不透明宿主对象引用（M2 §11；句柄型，恒非空）。 */
    public static const HOST_OBJECT: UInt16 = 14u16

    /** 装箱搬运类型（M3 §1；句柄型、恒非空；禁止二次装箱）。 */
    public static const ANY: UInt16 = 15u16

    /**
     * JSON 内建句柄类型（M3 §11/v0.3.20）：零注册、与 14 结构性无关。
     *
     * 码级继承：`JSON_OBJECT` / `JSON_ARRAY` / `JSON_NULL` 均为 `JSON_VALUE` 的子类；
     * 标量节点类（JsonInt/JsonDecimal/JsonBool/JsonString）的句柄码一律 `JSON_VALUE`。
     */
    public static const JSON_VALUE: UInt16 = 16u16
    public static const JSON_OBJECT: UInt16 = 17u16
    public static const JSON_ARRAY: UInt16 = 18u16
    public static const JSON_NULL: UInt16 = 19u16

    /** `fromToken` 的「无对应类型码」哨兵：不与 0–19 任何登记位撞（0xFFFF 在 §11.7 属保留区）。 */
    public static const NONE: UInt16 = 0xFFFFu16

    /**
     * 类型码 → 名称（调试 / 报告 / DbgDump 用）。
     *
     * 表按码**全表 0–19** 登记（plan-m1 S1.1「`name` 表与合法集按码全表（0–19）登记（供
     * DbgDump/诊断；本步填 0–12）」）：0–14 为 M1/M2 实名（M2 §2 追加 13=HostClosure、
     * 14=HostObject），15–19 是 M3（15=Any、16–19=JSON）的**预留登记位**，本步只占位不实名
     * （M3 追加实名时按 `design-m3 §2` 回填）。
     */
    public static func name(code: UInt16): String {
        match (code) {
            case 0u16 => 'Int64'
            case 1u16 => 'Float64'
            case 2u16 => 'Bool'
            case 3u16 => 'Unit'
            case 4u16 => 'String'
            case 5u16 => 'Decimal'
            case 6u16 => 'DateTime'
            case 7u16 => 'Duration'
            case 8u16 => 'Range'
            case 9u16 => 'Regex'
            case 10u16 => 'List'
            case 11u16 => 'Map'
            case 12u16 => 'Closure'
            case 13u16 => 'HostClosure'
            case 14u16 => 'HostObject'
            case 15u16 => 'Any'
            case 16u16 => 'JsonValue'
            case 17u16 => 'JsonObject'
            case 18u16 => 'JsonArray'
            case 19u16 => 'JsonNull'
            case _ =>
                if (code <= 255u16 && code >= 20u16) {
                    'Reserved(${code})'
                } else {
                    'Unknown(${code})'
                }
        }
    }

    /**
     * 句柄型判定：4–14 为真、0–3 为假（§11.7 值型/句柄型分界 + M2 §2 的 13/14）。
     *
     * 13（宿主闭包）与 14（不透明宿主对象）都是句柄型；M3 的 15（Any）与 16–19（JSON）
     * 同为句柄型（槽内存句柄 ID）；20 起是保留区，判假。
     * 该判定与版本无关——版本只约束**合法集**（`isLegal`），不改变类型归类。
     */
    public static func isHandle(code: UInt16): Bool {
        code >= 4u16 && code <= 19u16
    }

    /** JSON 内建码判定（16–19）。 */
    public static func isJson(code: UInt16): Bool {
        code >= 16u16 && code <= 19u16
    }

    /**
     * 可转集（M3 §1，**冻结**）：`0–8`、`9–11`、`14`、`16–19`。
     *
     * `12`（Closure）不开放转型、`13`（HostClosure）二期候选、`15`（Any）不在集合内
     * （盒不套盒）。该表是 `any_box` / `any_is` / `any_as` 的 `typecode` 合法域与前端
     * `is`/`as` 目标检查的**唯一来源**。
     */
    public static func isConvertible(code: UInt16): Bool {
        if (code <= 11u16) {
            return true
        }
        if (code == 12u16 || code == 13u16 || code == 15u16) {
            return false
        }
        code == 14u16 || (code >= 16u16 && code <= 19u16)
    }

    /** 是否有装箱发射点：只有 `3`（Unit）没有（M3 §2）。 */
    public static func hasBoxPoint(code: UInt16): Bool {
        code != 3u16
    }

    /** 码级继承：`T` 是否为 `base` 或其后代（M3 §11：17/18/19 <: 16）。 */
    public static func isSameOrDescendant(code: UInt16, base: UInt16): Bool {
        if (code == base) {
            return true
        }
        base == 16u16 && (code >= 17u16 && code <= 19u16)
    }

    /**
     * 类型 token → LocalType（§11.7 末段一一对应表，**映射集中在本方法一处**）：
     *
     * ```
     * List↔1、Map↔2、String↔3、Decimal↔4、DateTime↔5、Duration↔6、Range↔7、Regex↔8、Closure↔9
     * HostClosure↔10、HostObject↔11（M2 §2 增量）
     * ```
     *
     * token 0（保留，§6「加载器遇 0 拒绝」）与未定义 token ⇒ `NONE` 哨兵。
     */
    public static func fromToken(tok: UInt16): UInt16 {
        match (tok) {
            case 1u16 => LIST
            case 2u16 => MAP
            case 3u16 => STRING
            case 4u16 => DECIMAL
            case 5u16 => DATETIME
            case 6u16 => DURATION
            case 7u16 => RANGE
            case 8u16 => REGEX
            case 9u16 => CLOSURE
            case 10u16 => HOST_CLOSURE
            case 11u16 => HOST_OBJECT
            case 12u16 => ANY
            case _ => NONE
        }
    }

    /**
     * 合法类型码集**按字节码 `verMajor` 分派**（spec「版本分派合法集」、plan-m1 S1.1）：
     *
     * - `verMajor = 1` ⇒ 0–12（13 起拒绝，对应 §11.7「13–255 保留（加载器拒绝）」）；
     * - `verMajor = 2` ⇒ 0–14（M2 追加 13=HostClosure、14=HostObject）；
     * - `verMajor = 3` ⇒ 0–19（M3 追加 15=Any、16–19=JSON）；
     * - 其余主版本 ⇒ 一律拒绝（本加载器只到 v1，更高主版本按 §11.6 走 18 语义拒绝）。
     */
    public static func isLegal(code: UInt16, verMajor: UInt16): Bool {
        match (verMajor) {
            case 1u16 => code <= 12u16
            case 2u16 => code <= 14u16
            case 3u16 => code <= 19u16
            case _ => false
        }
    }
}

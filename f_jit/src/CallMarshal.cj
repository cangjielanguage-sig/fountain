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
import fountain::f_data.json.{JsonArray, JsonNull, JsonObject, JsonValue}
import fountain::f_jit.base.ErrCode
import fountain::f_jit.base.JitException
import fountain::f_jit.base.LocalType
import fountain::f_jit.base.TypeToken
import fountain::f_jit.runtime.HandleTable
import fountain::f_jit.runtime.HostCallback
import fountain::f_jit.runtime.JitClosure
import fountain::f_jit.runtime.PromotionGroup
import fountain::f_jit.runtime.SignatureDescriptor
import fountain::f_jit.runtime.SignatureVerifier

/**
 * S6.3 `CallMarshal`：§8.2.1 参数封送 / §8.2.2 返回解包 / 逃逸与清理。
 *
 * 契约错误一律 `JitException(19)`、`site=-1`、`sourcePos=None`（§8.2.3）；
 * **不做隐式宽化**、不接受 `Option`/null（句柄传 null → M1 不支持）。
 *
 * 生命周期：一次调用一个实例；`cleanup()` 释放本次 pin 的非逃逸槽（try/finally 义务）。
 */
protected class CallMarshal {
    /** 本次调用 pin 的窗口槽（B 路径）；escape 后移入 escaped。 */
    private let pinned = ArrayList<Int64>()
    private let escaped = ArrayList<Int64>()
    /** `retType=12` 时产出的提升组（`close` 的唯一释放路径）。 */
    private var closureGroup: ?PromotionGroup = None

    public init() {}

    /** 单参封送（§8.2.1 表；14 行可带声明类名做 `is C` 边界校验）。 */
    public func marshalArg(t: UInt16, v: Any, className!: ?String = None,
        sig!: ?SignatureDescriptor = None): Int64 {
        if (t == LocalType.HOST_CLOSURE) {
            return this.marshalHostClosure(v, sig)
        }
        if (t == LocalType.I64) {
            match (v as Int64) {
                case Some(x) => return x
                case None => return CallMarshal.contractFail('参数类型不符：期望 Int64')
            }
        }
        if (t == LocalType.F64) {
            match (v as Float64) {
                case Some(x) => return CallMarshal.bitsOf(x)
                case None => return CallMarshal.contractFail('参数类型不符：期望 Float64')
            }
        }
        if (t == LocalType.UNIT) {
            return 0
        }
        if (t == LocalType.BOOL) {
            match (v as Bool) {
                case Some(x) => return if (x) { 1 } else { 0 }
                case None => return CallMarshal.contractFail('参数类型不符：期望 Bool')
            }
        }
        if (t == LocalType.ANY) {
            // Any 行（R5.1）：任意宿主值（值型 / 引用型 / 闭包 / 实例 / 对象）→ 装箱 → 盒句柄。
            // 盒是值语义载体：宿主给什么就存什么，调用期由 `any_is` / `any_as` 做类型问答。
            let id = HandleTable.pinAnyBox(v)
            this.pinned.add(id)
            return id
        }
        if (t >= LocalType.JSON_VALUE && t <= LocalType.JSON_NULL) {
            // JSON 内建码（16–19）跨桥走 **token 11 例外行**（v0.3.20：不为 JSON 新开 token/tag）。
            // 只校验「是 JSON 节点」这一层：17/18/19 精确、16 收全部节点（码级继承）。
            if (!CallMarshal.jsonValueMatches(t, v)) {
                return CallMarshal.contractFail(
                    '参数不是 ${LocalType.name(t)} 节点（m3 §11：16–19 跨桥走 token 11）')
            }
            let id = HandleTable.pin(v)
            this.pinned.add(id)
            return id
        }
        if (t == LocalType.HOST_OBJECT) {
            // 源入口实参（m2 §16.2）：注册类实例以不透明 tag=11 进入；null/其他对象 → 19。
            if (HandleTable.tokenOf(v) != TypeToken.RESERVED) {
                return CallMarshal.contractFail('参数不是宿主类实例（§16.2）')
            }
            match (v) {
                case o: Object =>
                    match (className) {
                        case Some(cn) =>
                            if (!ReflectRegistrar.isInstanceOfClass(o, cn)) {
                                return CallMarshal.contractFail(
                                    '实参不是声明类「${cn}」的实例（§16.2 is C）')
                            }
                        case None => ()
                    }
                    let id = HandleTable.pinHostObject(o)
                    this.pinned.add(id)
                    return id
                case _ => return CallMarshal.contractFail('null/非对象不可作 14 型实参（§16.2）')
            }
        }
        if (CallMarshal.isHandleType(t)) {
            if (HandleTable.tokenOf(v) == TypeToken.RESERVED) {
                return CallMarshal.contractFail('参数不是可封送的句柄对象（§8.2.1）')
            }
            let id = HandleTable.pin(v)
            this.pinned.add(id)
            return id
        }
        CallMarshal.contractFail('该参数类型不可封送（§8.2.1）')
    }

    /** 按签名生成逐参封送器（任一失败即抛 19）。 */
    public func makeArgMarshalers(types: Array<UInt16>): Array<(Any) -> Int64> {
        let out = ArrayList<(Any) -> Int64>()
        var i = 0
        while (i < types.size) {
            let tt = types[i]
            out.add({ v => this.marshalArg(tt, v) })
            i = i + 1
        }
        out.toArray()
    }

    /** 13 型实参：单次 `is` 验签 → tag=10 pin（失败 19，site=-1）。 */
    public func marshalHostClosure(v: Any, declared: ?SignatureDescriptor): Int64 {
        let sig = match (declared) {
            case Some(s) => s
            case None => return CallMarshal.contractFail('HostClosure 参数缺少声明签名（m2 §4）')
        }
        // 反射验签：`FunctionTypeInfo` 取真实签名逐位比对（元数不受限、14 比具体类）。
        // H63 已同步改为 `reflectiveInvoke`（`FunctionTypeInfo.apply`），两侧口径一致。
        match (SignatureVerifier.verifyReflective(v, sig)) {
            case Some(verified) =>
                let id = HandleTable.pinHostClosure(v, verified)
                this.pinned.add(id)
                id
            case None =>
                CallMarshal.contractFail('HostClosure 验签失败（m2 §4）')
        }
    }

    /** 返回解包器（§8.2.2）：句柄型先逃逸再取对象。 */
    public func makeRetUnboxer(t: UInt16): (Int64) -> Any {
        { cell =>
            if (t == LocalType.I64) {
                return cell
            }
            if (t == LocalType.F64) {
                return Float64.fromBits(CallMarshal.bitsOfCell(cell))
            }
            if (t == LocalType.BOOL) {
                return cell != 0
            }
            if (t == LocalType.UNIT) {
                return ()
            }
            if (t == LocalType.CLOSURE) {
                return this.unboxClosure(cell)
            }
            if (t == LocalType.HOST_CLOSURE) {
                return this.unboxHostClosure(cell)
            }
            if (t == LocalType.HOST_OBJECT) {
                return this.escapeAndGetTyped(cell, TypeToken.HOST_OBJECT)
            }
            if (t == LocalType.ANY) {
                // Any 行（R5.2）：逃逸后拆盒，把**原生 Any** 交还宿主（不是盒句柄）
                HandleTable.escape(cell)
                CallMarshal.moveTo(this.pinned, this.escaped, cell)
                return HandleTable.fetchAnyBox(cell)
            }
            if (CallMarshal.isHandleType(t)) {
                return this.escapeAndGet(cell)
            }
            CallMarshal.contractFail('该返回类型不可解包（§8.2.2）')
        }
    }

    /** 路径 D：登记逃逸并取回对象；失败 → 19。 */
    public func escapeAndGet(id: Int64): Any {
        HandleTable.escape(id)
        CallMarshal.moveTo(this.pinned, this.escaped, id)
        match (HandleTable.getAny(id)) {
            case Some(v) => v
            case None => CallMarshal.contractFail('逃逸句柄取回失败')
        }
    }

    /** 带类型校验的逃逸取回（13/14 用槽位 tag 判定）。 */
    private func escapeAndGetTyped(id: Int64, tok: UInt16): Any {
        HandleTable.escape(id)
        CallMarshal.moveTo(this.pinned, this.escaped, id)
        match (HandleTable.getAs(id, tok)) {
            case Some(v) => v
            case None => CallMarshal.contractFail('逃逸句柄类型不符')
        }
    }

    /**
     * `retType=12`：闭包槽 + 全部句柄型捕获**原地提升**（槽级、免级联，§14.1/§14.6），
     * 解包为 `JitClosureId`。路径 A 常量与值型捕获不入组。
     */
    private func unboxClosure(cell: Int64): Any {
        match (HandleTable.getAs(cell, TypeToken.CLOSURE)) {
            case Some(v) =>
                match (v) {
                    case c: JitClosure =>
                        let group = PromotionGroup()
                        let visited = ArrayList<Int64>()
                        CallMarshal.promoteClosureGraph(cell, c, group, visited)
                        // 提升槽的唯一释放路径是包装器 close；本次调用的 try/finally 必须豁免。
                        for (pid in group.snapshot()) {
                            CallMarshal.removeFrom(this.pinned, pid)
                        }
                        this.closureGroup = Some(group)
                        JitClosureId(cell)
                    case _ => CallMarshal.contractFail('闭包槽载荷类型不符')
                }
            case None => CallMarshal.contractFail('闭包句柄无效（§14.3）')
        }
    }

    /** `retType=13`：原样带回宿主闭包引用（对象本属宿主，零拷贝）。 */
    private func unboxHostClosure(cell: Int64): Any {
        match (this.escapeAndGetTyped(cell, TypeToken.HOST_CLOSURE)) {
            case cb: HostCallback => cb.fn
            case _ => CallMarshal.contractFail('宿主闭包条目类型不符')
        }
    }

    /**
     * 提升闭包槽 + 句柄型捕获；捕获若仍是**内部闭包**（12）则递归（深层嵌套/自引用），
     * 容器不进入内部（§14.6 槽级、免级联）。`visited` 防止自引用环。
     */
    private static func promoteClosureGraph(cell: Int64, c: JitClosure,
        group: PromotionGroup, visited: ArrayList<Int64>): Unit {
        if (visited.contains(cell)) {
            return
        }
        visited.add(cell)
        group.add(cell)
        for (cap in c.captured) {
            if (cap <= 0 || !HandleTable.isLiveHandle(cap) || HandleTable.isConst(cap)) {
                continue
            }
            match (HandleTable.getAs(cap, TypeToken.CLOSURE)) {
                case Some(v) =>
                    match (v) {
                        case inner: JitClosure =>
                            CallMarshal.promoteClosureGraph(cap, inner, group, visited)
                        case _ => group.add(cap)
                    }
                case None => group.add(cap)
            }
        }
    }

    /** `retType=12` 产出的提升组（桥据此构造包装器）。 */
    public func closureGroupOf(): ?PromotionGroup {
        this.closureGroup
    }

    /** 释放本次调用登记的**非逃逸**槽；幂等。 */
    public func cleanup(): Unit {
        for (id in this.pinned) {
            if (!HandleTable.isConst(id)) {
                HandleTable.release(id)
            }
        }
        this.pinned.clear()
    }

    /** 本次 pin 且已逃逸的句柄（供桥的逃逸区接管）。 */
    public func escapedIds(): Array<Int64> {
        this.escaped.toArray()
    }

    private static func removeFrom(from: ArrayList<Int64>, id: Int64): Unit {
        var i = 0
        while (i < from.size) {
            if (from[i] == id) {
                from.remove(at: i)
                return
            }
            i = i + 1
        }
    }

    private static func moveTo(from: ArrayList<Int64>, to: ArrayList<Int64>, id: Int64): Unit {
        var i = 0
        while (i < from.size) {
            if (from[i] == id) {
                to.add(id)
                from.remove(at: i)
                return
            }
            i = i + 1
        }
        to.add(id)
    }

    /** 句柄型 LocalType：4–11（String..Map）、12（内部闭包）、13（宿主闭包）、14（宿主对象）。 */
    /**
     * 句柄型码集：4–14 与 **16–19**（JSON 内建码；跨桥走 token 11 例外行）。
     *
     * 15（Any 盒）不在其中——盒的封送属 R5「Marshal Any 行」。
     */
    private static func isHandleType(t: UInt16): Bool {
        (t >= LocalType.STRING && t <= LocalType.HOST_OBJECT) ||
            (t >= LocalType.JSON_VALUE && t <= LocalType.JSON_NULL)
    }

    /** JSON 内建码的运行时类判定（17/18/19 精确；16 收全部节点）。 */
    private static func jsonValueMatches(code: UInt16, v: Any): Bool {
        if (code == LocalType.JSON_VALUE) {
            return v is JsonValue
        }
        if (code == LocalType.JSON_OBJECT) {
            return v is JsonObject
        }
        if (code == LocalType.JSON_ARRAY) {
            return v is JsonArray
        }
        if (code == LocalType.JSON_NULL) {
            return v is JsonNull
        }
        false
    }

    private static func bitsOf(v: Float64): Int64 {
        CallMarshal.bitsOfCell2(v.toBits())
    }

    private static func bitsOfCell2(bits: UInt64): Int64 {
        if (bits >= 0x8000000000000000u64) {
            Int64(bits - 0x8000000000000000u64) + Int64.Min
        } else {
            Int64(bits)
        }
    }

    private static func bitsOfCell(cell: Int64): UInt64 {
        if (cell < 0) {
            UInt64(cell - Int64.Min) + 0x8000000000000000u64
        } else {
            UInt64(cell)
        }
    }

    private static func contractFail(msg: String): Int64 {
        throw JitException(ErrCode.CALL_CONTRACT, -1, 0, None, msg)
    }
}

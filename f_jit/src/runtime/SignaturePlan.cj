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
import std.reflect.FunctionTypeInfo
import fountain::f_jit.base.ErrCode
import std.sync.Mutex

/**
 * CALL_HOST 转发特化（m3 §13 / R4.10–R4.12）。
 *
 * 三层结构：
 * - **Layer A `SignatureTable`**：签名级、**身份无关**（键 = 形参码序列 + 返回码）；验签即建；
 * - **Layer B `HostCallback.plan`**：条目级绑定，per-call 直通；
 * - **Layer C 开关**：`enabled = false` 强制走通用路径（R5.5 对拍用）。
 *
 * 纯加速：计划只缓存「cell → 宿主值」的转换器序列与装配顺序，**不改变任何语义**；
 * 冷路径（未命中 / 超过条目上限 / 开关关闭）沿用 `reflectiveInvoke`。
 */
public class SignaturePlan {
    /** 形参码序列（造计划时的快照）。 */
    public let params: Array<UInt16>
    /** 返回码。 */
    public let ret: UInt16
    /** 元数（= `params.size`）。 */
    public let argc: Int64

    /**
     * 逐参转换器：`(cell) -> 宿主值`，造计划时按码固化，调用期零分支。
     *
     * 与通用路径**共用** `cellToHostValue`——两路逐位一致的前提。
     */
    private let converters: Array<(Int64) -> Any>

    public init(sig: SignatureDescriptor) {
        this.params = sig.params.clone()
        this.ret = sig.ret
        this.argc = Int64(sig.params.size)
        let cs = ArrayList<(Int64) -> Any>()
        for (c in sig.params) {
            cs.add({ cell => cellToHostValue(c, cell) })
        }
        this.converters = cs.toArray()
    }

    /** 同结构判定（身份无关）：形参码序列 + 返回码相等。 */
    public func sameShape(p: Array<UInt16>, r: UInt16): Bool {
        if (r != this.ret || p.size != this.params.size) {
            return false
        }
        var i = 0
        while (i < p.size) {
            if (p[i] != this.params[i]) {
                return false
            }
            i = i + 1
        }
        true
    }

    /**
     * 逐参转换 + 装配（`a[0]` 是 h_fn，实参从 `a[1]` 起）。
     *
     * argc ≤ 4 走**展开**模板、> 4 走**循环**——两条路径调同一批转换器，结果逐位一致；
     * 展开只是省掉循环控制开销，**不是**形参数量限制（argc 域仍 0–255）。
     */
    public func marshalArgs(a: Array<Int64>): Array<Any> {
        let n = this.argc
        let out = Array<Any>(n, repeat: 0)
        if (n <= 4) {
            if (n > 0) {
                out[0] = this.converters[0](a[1])
            }
            if (n > 1) {
                out[1] = this.converters[1](a[2])
            }
            if (n > 2) {
                out[2] = this.converters[2](a[3])
            }
            if (n > 3) {
                out[3] = this.converters[3](a[4])
            }
        } else {
            var i = 0
            while (i < n) {
                out[i] = this.converters[i](a[i + 1])
                i = i + 1
            }
        }
        out
    }
}

/**
 * 签名级计划表（m3 §13.1）：**验签即建**、同签名复用、条目数有界、并发首建安全。
 *
 * `enabled = false` 时 `getOrBuild` 一律返回 `None`（强制通用路径，供 R5.5 对拍）。
 */
public class SignatureTable {
    private static let mtx = Mutex()
    private static let entries = ArrayList<SignaturePlan>()
    private static var builds = 0

    /** 特化总开关（测试与宿主可关；关闭后新建条目一律无计划）。 */
    public static var enabled = true

    /** 条目上限：超过后**不再缓存**（冷路径每次现造，行为不变、内存有界）。 */
    public static let MAX_ENTRIES = 128

    /** 取或建计划；`enabled = false` → `None`。 */
    public static func getOrBuild(sig: SignatureDescriptor): ?SignaturePlan {
        if (!enabled) {
            return None
        }
        synchronized(mtx) {
            var i = 0
            while (i < entries.size) {
                if (entries[i].sameShape(sig.params, sig.ret)) {
                    return Some(entries[i])
                }
                i = i + 1
            }
            builds = builds + 1
            let p = SignaturePlan(sig)
            if (entries.size < MAX_ENTRIES) {
                entries.add(p)
            }
            Some(p)
        }
    }

    /** 实际**新建**的计划数（对拍/断言用：同签名只建一次）。 */
    public static func buildCount(): Int64 {
        synchronized(mtx) {
            builds
        }
    }

    public static func entryCount(): Int64 {
        synchronized(mtx) {
            entries.size
        }
    }

    /** 测试专用：清空表与计数、恢复开关。 */
    public static func resetForTest(): Unit {
        synchronized(mtx) {
            entries.clear()
            builds = 0
        }
        enabled = true
    }
}

/**
 * 带计划的反射调用：与 `reflectiveInvoke` 只差「实参装配」这一步——转换器已固化在计划里，
 * 不再逐次读 `sig.params[i]`。`apply` 仍是同一次调用（异常照旧冒泡到 H63）。
 */
internal func reflectiveInvokeWithPlan(fn: Any, cached: ?FunctionTypeInfo, plan: SignaturePlan,
    a: Array<Int64>): Any {
    let ti = match (cached) {
        case Some(t) => t
        case None =>
            try {
                FunctionTypeInfo.of(fn)
            } catch (e: Exception) {
                failWith(ErrCode.HELPER_PANIC)
            }
    }
    if (Int64(ti.parameters.size) != plan.argc) {
        // 描述符与函数值元数不符：与通用路径同口径（引擎侧失败 → 99，不是宿主异常 21）
        failWith(ErrCode.HELPER_PANIC)
    }
    ti.apply(fn, plan.marshalArgs(a))
}

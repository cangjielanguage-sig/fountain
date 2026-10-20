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

import std.reflect.FunctionTypeInfo
import fountain::f_jit.base.ErrCode
import fountain::f_jit.base.LocalType
import fountain::f_jit.base.TypeToken

/**
 * 宿主闭包的**反射调用**（GAP-05 乙的落地）。
 *
 * 为什么不用 `invokeN<P1..Pn, R>` 的静态绑定：JIT 在运行期编译，产出不了新的泛型单态化实例；
 * 而把签名空间物化成静态分支是 11^(n+1) 的组合爆炸（2 元已 1331 支、3 元 14641 支）。
 *
 * `FunctionTypeInfo.apply(instance, args)` 是第四条路：按实参数组调用任意元数，运行期零类型分派。
 * 逐参的 cell → 仓颉值转换仍由本层完成（与 H65 的取值口径一致）。
 *
 * 代价是走反射调用（`ApplyCJInstanceMethod`），开销需与 user helper 对照实测（见 perf-m2）。
 */
internal func reflectiveInvoke(fn: Any, cached: ?FunctionTypeInfo, sig: SignatureDescriptor,
    a: Array<Int64>): Any {
    let ti = match (cached) {
        case Some(t) => t
        case None =>
            // 条目未缓存（老路径/非闭包条目）：回退到现场探测
            try {
                FunctionTypeInfo.of(fn)
            } catch (e: Exception) {
                failWith(ErrCode.HELPER_PANIC)
            }
    }
    if (Int64(ti.parameters.size) != Int64(sig.params.size)) {
        // 描述符与函数值不匹配：H63 已校验 nargs == sig.params.size，走到这里是内部不一致
        failWith(ErrCode.HELPER_PANIC)
    }
    let args = convertArgs(sig, a)
    // **不捕获** apply 的异常：宿主业务异常必须冒到 H63，由它统一转 21 + cause（v0.8.19 §13-6）。
    // 这里若吞成 19，`hostExceptionMapsTo21WithCause` 一类用例会全线失败，且语义颠倒。
    ti.apply(fn, args)
}

/**
 * 逐参 cell → 仓颉值（M2.2 抽出）：反射路径与类型化 adapter 路径**共用**。
 *
 * `a[0]` 是 h_fn，实参从 `a[1]` 起。
 */
internal func convertArgs(sig: SignatureDescriptor, a: Array<Int64>): Array<Any> {
    let args = Array<Any>(sig.params.size, repeat: 0)
    var i = 0
    while (i < sig.params.size) {
        args[i] = cellToHostValue(sig.params[i], a[i + 1])
        i = i + 1
    }
    args
}

/**
 * cell → 仓颉值（按 `LocalType` 码）：值型原值、句柄型取表、14 取实例引用。
 *
 * 与 `hostSetField` 的取值分支同口径；差异只在失败码（这里 `CALL_CONTRACT`，
 * 字段写那边是防御性 `HELPER_PANIC`）。
 */
internal func cellToHostValue(code: UInt16, cell: Int64): Any {
    match (code) {
        case 0u16 => cell
        case 1u16 => Float64.fromBits(UInt64(cell))
        case 2u16 => cell != 0
        case 3u16 => ()
        case 14u16 => HandleTable.fetchHostObject(cell)
        case _ =>
            let tok = signatureToken(code)
            if (tok == TypeToken.RESERVED) {
                failWith(ErrCode.HELPER_PANIC)
            }
            HandleTable.fetchAny(cell, tok)
    }
}

/** `LocalType`（句柄型 4–13）→ `TypeToken`；14 单独走 `fetchHostObject`。 */
private func signatureToken(code: UInt16): UInt16 {
    match (code) {
        case 4u16 => TypeToken.STRING
        case 5u16 => TypeToken.DECIMAL
        case 6u16 => TypeToken.DATETIME
        case 7u16 => TypeToken.DURATION
        case 8u16 => TypeToken.RANGE
        case 9u16 => TypeToken.REGEX
        case 10u16 => TypeToken.LIST
        case 11u16 => TypeToken.MAP
        case 12u16 => TypeToken.CLOSURE
        case 13u16 => TypeToken.HOST_CLOSURE
        case _ => TypeToken.RESERVED
    }
}

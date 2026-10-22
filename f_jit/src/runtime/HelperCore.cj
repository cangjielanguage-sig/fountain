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
import std.math.numeric.BigInt
import std.math.numeric.Decimal
import std.time.DateTime
import fountain::f_base.*
import fountain::f_jit.base.ErrCode
import fountain::f_jit.base.TypeToken

/**
 * 多级写码（§9 附则 5 / §9.5）+ helper 分派入口 —— plan-m1 S4.18。
 *
 * **错误通道单一**（design D5）：错误只经 ctx 错误槽单向传递；helper 内部 try/catch 把异常
 * 转码为错误码，**绝不把异常抛给字节码或机器码**；异常只出现在宿主边界（桥的 errCode→异常）。
 *
 * 写码规则（§9.5 冻结）：
 *
 * 1. 槽为 0（未写码）⇒ 写入本次错误码；
 * 2. 槽已写码且**没有新的异常信息**（仅错误码）⇒ **保留内层错误码与站点**（最深失败帧获胜，
 *    与 §9.16「首个收敛点获胜」同口径）；
 * 3. 槽已写码但外层**捕获到新异常** ⇒ 覆盖（新异常信息优先）；
 * 4. 末尾 catch-all 兜 `ERR_HELPER_PANIC(99)`，且必须能吞掉一切。
 */
public class HelperCore {
    /** 写码（无新异常信息）：仅当槽为空时写入。 */
    public static func ctxWriteCode(ctx: JitContext, code: Int64): Unit {
        if (ctx.errCode == 0) {
            ctx.errCode = code
        }
    }

    /** 写码（**捕获到新异常**）：覆盖既有错误码。 */
    public static func ctxWriteCode(ctx: JitContext, code: Int64, e: Exception): Unit {
        ctx.errCode = code
    }

    /** 末尾 catch-all：兜 99（槽为空时写；已有码时按「新异常信息覆盖」写入）。 */
    public static func ctxWritePanic(ctx: JitContext, e: Exception): Unit {
        ctx.errCode = ErrCode.HELPER_PANIC
    }
}

/**
 * helper 调用入口（解释器与机器码共用同一份仓颉实现 —— design D4「三引擎共用一份 helper」）。
 *
 * 失败一律转成错误码写槽，**不向上传播异常**；返回值在失败时未定义（I5），调用方必须先读槽。
 */
public func invokeHelper(ctx: JitContext, hid: Int64, a: Array<Int64>): Int64 {
    try {
        dispatchHelper(ctx, hid, a)
    } catch (e: HelperFail) {
        HelperCore.ctxWriteCode(ctx, e.code)
        0
    } catch (e: Exception) {
        HelperCore.ctxWritePanic(ctx, e)
        0
    }
}

/** 分配型 helper 的统一登记口（恰好 1 槽；窗口满则倍增，触顶 → 16）。 */
internal func allocValue(ctx: JitContext, obj: Any): Int64 {
    let tok = HandleTable.tokenOf(obj)
    if (tok == TypeToken.RESERVED) {
        failWith(ErrCode.HELPER_PANIC)
    }
    HandleTable.append(ctx, obj, tok)
}

/** 取第 `i` 个实参；越界 ⇒ 防御码 99（helper ABI 的 argc 由汇编器保证）。 */
internal func argAt(a: Array<Int64>, i: Int64): Int64 {
    if (i < 0 || i >= a.size) {
        failWith(ErrCode.HELPER_PANIC)
    }
    a[i]
}

/** 容器元素 / Map 键的规范 token —— 与 `ConstRegistry.tokenOf` **同口径**（常量键与运行期键
 *  必须落在同一键空间，否则常量 Map 的查找会不命中）。 */
internal func tokenOfValue(v: Any): String {
    match (v) {
        case i: Int64 => 'i${i}'
        case f: Float64 => 'f${f.toBits()}'
        case b: Bool => 'b${b}'
        case s: String => 's${s}'
        case d: Decimal => 'd${decTriple(d)[0]}|${decTriple(d)[1]}|${decTriple(d)[2]}'
        case t: DateTime => 't${t.toUnixTimeStamp().toNanoseconds()}'
        case u: Duration => 'u${u.toNanoseconds()}'
        case r: Range<Int64> => 'r${r.start}|${r.end}|${r.step}|${r.isClosed}'
        case x: JitRegex => 'x${x.flags}|${x.re.string()}'
        case _ => '?${HandleTable.tokenOf(v)}'
    }
}

/** Decimal → `(sign, scale, 系数数字串)`（与 §11.5 kind 6 的表示同形）。 */
internal func decTriple(v: Decimal): (UInt8, Int32, String) {
    let bs = v.toString().unsafeBytes()
    var sign: UInt8 = 0u8
    var digits = ArrayList<UInt8>()
    var scale: Int64 = 0
    var seenDot = false
    var i = 0
    for (b in bs) {
        if (b == 0x2Du8 && i == 0) {
            sign = 1u8
        } else if (b == 0x2Eu8) {
            seenDot = true
        } else if (b >= 0x30u8 && b <= 0x39u8) {
            digits.add(b)
            if (seenDot) {
                scale = scale + 1
            }
        }
        i = i + 1
    }
    (sign, Int32(scale), String.fromUtf8(digits.toArray()))
}

/** 由 `(sign, scale, 系数)` 构造 Decimal（std 任意精度，§9 附则 12）。 */
internal func decFromTriple(sign: UInt8, scale: Int32, coeff: String): Decimal {
    var mag = BigInt.parse(coeff)
    if (sign != 0u8) {
        mag = -mag
    }
    Decimal(mag, scale)
}

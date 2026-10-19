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
import fountain::f_jit.base.ErrCode
import fountain::f_jit.base.JitException
import fountain::f_jit.base.LocalType
import fountain::f_jit.base.TypeToken
import fountain::f_jit.runtime.HandleTable

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

    public init() {}

    /** 单参封送（§8.2.1 表）。 */
    public func marshalArg(t: UInt16, v: Any): Int64 {
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
        if (t == LocalType.BOOL) {
            match (v as Bool) {
                case Some(x) => return if (x) { 1 } else { 0 }
                case None => return CallMarshal.contractFail('参数类型不符：期望 Bool')
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

    /** 句柄型 LocalType：4–11（String/Decimal/DateTime/Duration/Range/Regex/List/Map）。 */
    private static func isHandleType(t: UInt16): Bool {
        t >= LocalType.STRING && t <= LocalType.MAP
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

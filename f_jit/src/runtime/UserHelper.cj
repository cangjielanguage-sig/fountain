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
import std.sync.Mutex
import fountain::f_jit.base.ErrCode
import fountain::f_jit.base.LocalType
import fountain::f_jit.base.TypeToken

/**
 * 单元私有预定义函数（user helper）的运行期条目（m2 §15 / §8.4）。
 *
 * `params` / `ret` 是注册快照里的 LocalType 签名；`impl` 收**已解包**的仓颉值。
 * 构造器物化条目：`params = PublicCtor.params`、`ret = 14`。
 */
public class UserHelperEntry {
    public let params: Array<UInt16>
    public let ret: UInt16
    public let impl: (Array<Any>) -> Any

    public init(params!: Array<UInt16>, ret!: UInt16, impl!: (Array<Any>) -> Any) {
        this.params = params.clone()
        this.ret = ret
        this.impl = impl
    }
}

/**
 * user helper 的**调用级**活动表（`hid = 0x0100 + slot`）。
 *
 * 用栈而不是进程级单表：同一 `hid` 在不同单元里含义不同；桥调用串行化，嵌套调用
 * （如宿主闭包内重入）按栈顶优先查找，退出时弹回外层。
 */
public class UserHelperTable {
    private static let mtx = Mutex()
    private static let stack = ArrayList<HashMap<Int64, UserHelperEntry>>()

    /** 压入一次调用单元的 helper 表（`base` 通常为 0，表示 hid 从 0x0100 起）。 */
    public static func push(base: UInt16, entries: Array<UserHelperEntry>): Unit {
        let table = HashMap<Int64, UserHelperEntry>()
        var i = 0
        while (i < entries.size) {
            table.add(Int64(HelperId.USER_BASE) + Int64(base) + Int64(i), entries[i])
            i = i + 1
        }
        synchronized(mtx) {
            stack.add(table)
        }
    }

    /** 弹出顶层表；空栈幂等。 */
    public static func pop(): Unit {
        synchronized(mtx) {
            if (stack.size > 0) {
                stack.remove(at: stack.size - 1)
            }
        }
    }

    /** 查找 hid：栈顶优先，向下回退。 */
    public static func find(hid: Int64): ?UserHelperEntry {
        synchronized(mtx) {
            var i = stack.size - 1
            while (i >= 0) {
                match (stack[i].get(hid)) {
                    case Some(e) => return Some(e)
                    case None => ()
                }
                i = i - 1
            }
            None
        }
    }

    /** 测试专用：清空活动栈。 */
    public static func resetForTest(): Unit {
        synchronized(mtx) {
            stack.clear()
        }
    }
}

/** user helper 执行：逐参 cell → 仓颉值 → `impl` → 返回值 cell。 */
internal func invokeUserHelper(ctx: JitContext, hid: Int64, a: Array<Int64>): Int64 {
    let entry = match (UserHelperTable.find(hid)) {
        case Some(e) => e
        case None => failWith(ErrCode.NOT_IMPL)
    }
    if (a.size != entry.params.size) {
        failWith(ErrCode.HELPER_PANIC)
    }
    let args = Array<Any>(a.size, repeat: 0)
    var i = 0
    while (i < a.size) {
        args[i] = userHelperArg(entry.params[i], a[i])
        i = i + 1
    }
    var r: Any = 0
    try {
        r = entry.impl(args)
    } catch (e: HelperFail) {
        throw e
    } catch (e: Exception) {
        HostFault.record(ctx, e)
        failWith(ErrCode.HOST_EXCEPTION)
    }
    hostResultCell(ctx, entry.ret, r)
}

/** 逐参转换（与 H63 逐参转换同口径；13 取宿主闭包值、14 取实例引用）。 */
private func userHelperArg(code: UInt16, cell: Int64): Any {
    match (code) {
        case 0u16 => cell
        case 1u16 => Float64.fromBits(UInt64(cell))
        case 2u16 => cell != 0
        case 3u16 => ()
        case 13u16 => HandleTable.fetchHostCallback(cell).fn
        case 14u16 => HandleTable.fetchHostObject(cell)
        case _ =>
            let tok = userHelperToken(code)
            if (tok == TypeToken.RESERVED) {
                failWith(ErrCode.HELPER_PANIC)
            }
            HandleTable.fetchAny(cell, tok)
    }
}

private func userHelperToken(code: UInt16): UInt16 {
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
        case _ => TypeToken.RESERVED
    }
}

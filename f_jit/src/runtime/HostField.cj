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
 * 宿主字段访问器 —— H64/H65 的宿主实现入口（m2 §12.2 / §12.5）。
 *
 * 一条注册项 = 一个 `(index, 声明类型, mutable, 目标类判定, getter, setter)`：
 *
 * - `accepts` 在注册期由宿主静态类知识生成（`o is C`），使 index 的**类内序号**语义在运行期
 *   可判定（不同类的 index 可重复）；
 * - `getter` / `setter` 是宿主黑盒（手工适配器或反射访问器），执行期**零反射**（I2）；
 * - H64/H65 只按 index + `accepts` 选唯一访问器，再做值型/句柄型 marshal。
 */
public class HostFieldAccessor {
    /** 字段声明类型（LocalType 0–14）。 */
    public let `type`: UInt16

    /** `var` / `let` 标志（`false` ⇒ 裸 H65 防御 19）。 */
    public let mutable: Bool

    /** 目标类判定（注册期静态知识，如 `{ o => o is User }`）。 */
    public let accepts: (Object) -> Bool

    /** 读访问器：返回宿主仓颉值（值型原值 / 句柄型对象引用）。 */
    public let getter: (Object) -> Any

    /** 写访问器：接收已解包的宿主仓颉值。 */
    public let setter: (Object, Any) -> Unit

    public init(`type`!: UInt16, mutable!: Bool, accepts!: (Object) -> Bool,
        getter!: (Object) -> Any, setter!: (Object, Any) -> Unit) {
        this.`type` = `type`
        this.mutable = mutable
        this.accepts = accepts
        this.getter = getter
        this.setter = setter
    }
}

/**
 * 运行期字段表（进程级；宿主侧注册、执行期只读查找）。
 *
 * 注册来源：手工类注册（§12.4）与反射自动注册（§12.5）都会把访问器登记到这里；H64/H65
 * 只看到 `(obj, index)`，故用 index 分桶 + `accepts` 判定实际类。表项在注册后不再变更
 * （快照语义由编译期描述符承担；本表只服务已编译单元的运行期访问）。
 */
public class HostFieldTable {
    private static let mtx = Mutex()
    private static let buckets = HashMap<UInt16, ArrayList<HostFieldAccessor>>()

    /** 登记一个字段访问器（同 index 可登记多个类；查找按注册序 + `accepts`）。 */
    public static func register(index!: UInt16, `type`!: UInt16, mutable!: Bool,
        accepts!: (Object) -> Bool, getter!: (Object) -> Any,
        setter!: (Object, Any) -> Unit): Unit {
        let acc = HostFieldAccessor(`type`: `type`, mutable: mutable, accepts: accepts,
            getter: getter, setter: setter)
        synchronized(mtx) {
            match (buckets.get(index)) {
                case Some(list) => list.add(acc)
                case None =>
                    let list = ArrayList<HostFieldAccessor>()
                    list.add(acc)
                    buckets.add(index, list)
            }
        }
    }

    /**
     * 按 index + 实际对象定位访问器；未命中 ⇒ `None`（由 helper 转 99，运行期防御）。
     *
     * `accepts` 在锁外求值：访问器是宿主闭包，可能重入字段表（不得持锁调用）。
     */
    public static func find(obj: Object, index: UInt16): ?HostFieldAccessor {
        var list = ArrayList<HostFieldAccessor>()
        synchronized(mtx) {
            match (buckets.get(index)) {
                case Some(src) =>
                    for (e in src) {
                        list.add(e)
                    }
                case None => ()
            }
        }
        for (e in list) {
            if (e.accepts(obj)) {
                return Some(e)
            }
        }
        None
    }

    /** 测试专用：清空字段表。 */
    public static func resetForTest(): Unit {
        synchronized(mtx) {
            buckets.clear()
        }
    }
}

// ============================================================================
// H64 / H65（m2 §12.2）
// ============================================================================

/**
 * H64 `host_get_field(obj, index)`：值型直取原值（零登记）；句柄型（4–14）登记 1 槽。
 *
 * 失败：`obj` 非 tag 11 / null ⇒ 8 / 6（既有 fetch 语义）；index 未登记、访问器类型不符 ⇒ 99。
 */
internal func hostGetField(ctx: JitContext, a: Array<Int64>): Int64 {
    let obj = HandleTable.fetchHostObject(argAt(a, 0))
    let index = argAt(a, 1)
    if (index < 0 || index > 65535) {
        failWith(ErrCode.HELPER_PANIC)
    }
    let acc = match (HostFieldTable.find(obj, UInt16(index))) {
        case Some(x) => x
        case None => failWith(ErrCode.HELPER_PANIC)
    }
    // v0.8.19 §13-6：成员访问器执行期异常归属宿主异常专用码 21（原 99 收窄为引擎面）。
    let v = try {
        acc.getter(obj)
    } catch (e: HelperFail) {
        throw e
    } catch (e: Exception) {
        HostFault.record(ctx, e)
        failWith(ErrCode.HOST_EXCEPTION)
    }
    match (acc.`type`) {
        case 0u16 => match (v) {
            case i: Int64 => i
            case _ => failWith(ErrCode.HELPER_PANIC)
        }
        case 1u16 => match (v) {
            case f: Float64 => Int64(f.toBits())
            case _ => failWith(ErrCode.HELPER_PANIC)
        }
        case 2u16 => match (v) {
            case b: Bool => if (b) { 1 } else { 0 }
            case _ => failWith(ErrCode.HELPER_PANIC)
        }
        case 3u16 =>
            let _ = v
            0
        case 14u16 => match (v) {
            case o: Object => HandleTable.append(ctx, o, TypeToken.HOST_OBJECT)
            case _ => failWith(ErrCode.HELPER_PANIC)
        }
        case _ => handleFieldCell(ctx, acc.`type`, v)
    }
}

/** 句柄型字段（4–13）：校验实际大类后登记 1 槽（分配型语义，同 H63 返回值）。 */
private func handleFieldCell(ctx: JitContext, code: UInt16, v: Any): Int64 {
    let want = fieldToken(code)
    if (want == TypeToken.RESERVED || HandleTable.tokenOf(v) != want) {
        failWith(ErrCode.HELPER_PANIC)
    }
    allocValue(ctx, v)
}

/**
 * H65 `host_set_field(obj, index, cell)`：值型直存、句柄型 fetch 后存对象引用。
 *
 * **变更型**：不登记槽；`mutable=false` ⇒ 19（语法糖编译期为主防线的运行期兜底）。
 * 失败：`obj` 非 tag 11 ⇒ 8；`let` 写 ⇒ 19；index/类型防御 ⇒ 99。
 */
internal func hostSetField(ctx: JitContext, a: Array<Int64>): Int64 {
    let obj = HandleTable.fetchHostObject(argAt(a, 0))
    let index = argAt(a, 1)
    let cell = argAt(a, 2)
    if (index < 0 || index > 65535) {
        failWith(ErrCode.HELPER_PANIC)
    }
    let acc = match (HostFieldTable.find(obj, UInt16(index))) {
        case Some(x) => x
        case None => failWith(ErrCode.HELPER_PANIC)
    }
    if (!acc.mutable) {
        failWith(ErrCode.READONLY)
    }
    let v: Any = match (acc.`type`) {
        case 0u16 => cell
        case 1u16 => Float64.fromBits(UInt64(cell))
        case 2u16 => cell != 0
        case 3u16 => ()
        case 14u16 => HandleTable.fetchHostObject(cell)
        case _ =>
            let tok = fieldToken(acc.`type`)
            if (tok == TypeToken.RESERVED) {
                failWith(ErrCode.HELPER_PANIC)
            }
            HandleTable.fetchAny(cell, tok)
    }
    try {
        acc.setter(obj, v)
    } catch (e: HelperFail) {
        throw e
    } catch (e: Exception) {
        HostFault.record(ctx, e)
        failWith(ErrCode.HOST_EXCEPTION)
    }
    0
}

/** LocalType（句柄型 4–13）→ TypeToken；14 单独处理（tag 11 是显式大类）。 */
private func fieldToken(code: UInt16): UInt16 {
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

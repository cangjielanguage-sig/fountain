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
import fountain::f_data.json.{JsonArray, JsonNull, JsonObject, JsonValue}
import fountain::f_jit.base.ErrCode
import fountain::f_jit.base.LocalType
import fountain::f_jit.base.TypeToken
import fountain::f_jit.bytecode.ConstMapKey

/**
 * M3 Any 通道：H78 `any_box` / H79 `any_is` / H80 `any_as`（m3 §5）。
 *
 * 盒 = 句柄条目直存原生 `Any`（tag 12）；唯一算子 = `is` / `as`。`as` 是本方言的
 * **强制转型**（未命中 → 22），不是仓颉的 `as`（后者返回 `Option`）。
 *
 * 14 目标的类界（A2/D1）：`aux != 0xFFFF` 时委托给该 hid 对应的 `$as$<C>`（注册期合成的
 * `(14) -> Bool`），子类实例命中、无关类与向下转型不命中；`aux == 0xFFFF` 保留「任意非 JSON
 * 宿主对象」的兼容口径（仅当前端拿不到类名时出现）。命中后的句柄恒以 tag **11** 登记并计入
 * 窗口（`appendHostObject`）；容器 `aux` 只校验元素为 `Any`（其余元素码走同一分派表）。
 */

/** H78：`any_box(typecode, cell) → h`（分配型，登记 1 槽）。 */
internal func anyBox(ctx: JitContext, a: Array<Int64>): Int64 {
    let code = UInt16(argAt(a, 0))
    // 可转集之外（含 12/13/15）不得装箱：8 = HANDLE_TYPE（契约类错误）
    if (!LocalType.isConvertible(code) || code == LocalType.ANY) {
        failWith(ErrCode.HANDLE_TYPE)
    }
    // 世界内分配：计入窗口（m3 §8）；桥侧 `CallMarshal` 仍走 `pinAnyBox`
    HandleTable.appendAnyBox(ctx, anyValueOf(code, argAt(a, 1)))
}

/** H79：`any_is(box, typecode, aux) → 0/1`（纯读；集合外类型答 0，不是错误）。 */
internal func anyIs(ctx: JitContext, a: Array<Int64>): Int64 {
    let unused = ctx
    let _ = unused
    let v = HandleTable.fetchAnyBox(argAt(a, 0))
    let code = UInt16(argAt(a, 1))
    let aux = argAt(a, 2)
    if (anyMatches(v, code, aux)) {
        1
    } else {
        0
    }
}

/** H80：`any_as(box, typecode, aux) → cell`（命中 → 值型直返 / 句柄型窗口内登记；未命中 → 22）。 */
internal func anyAs(ctx: JitContext, a: Array<Int64>): Int64 {
    let v = HandleTable.fetchAnyBox(argAt(a, 0))
    let code = UInt16(argAt(a, 1))
    let aux = argAt(a, 2)
    if (!anyMatches(v, code, aux)) {
        failWith(ErrCode.ANY_CAST)
    }
    let src = argAt(a, 0)
    // 注：本方言源码里的 `as T` 返回 `Option<T>`（那是仓颉语义），宿主侧取值必须用 match
    match (code) {
        case 0u16 =>
            match (v) {
                case i: Int64 => i
                case _ => failWith(ErrCode.ANY_CAST)
            }
        case 1u16 =>
            match (v) {
                case f: Float64 => Int64(f.toBits())
                case _ => failWith(ErrCode.ANY_CAST)
            }
        case 2u16 =>
            match (v) {
                case b: Bool => if (b) { 1 } else { 0 }
                case _ => failWith(ErrCode.ANY_CAST)
            }
        case 3u16 => 0
        case 14u16 =>
            // 14 恒以 tag 11 登记（不走通用 `pin`：注册类实例无内建 token，会被拒成 19）
            let out = match (v) {
                case o: Object => HandleTable.appendHostObject(ctx, o)
                case _ => failWith(ErrCode.HANDLE_TYPE)
            }
            propagateFrozen(src, out)
            out
        case _ =>
            // 4–11 与 16–19：句柄型分支统一走窗口内分配（A2/P2-6 记账）
            let tok = HandleTable.tokenOf(v)
            if (tok == TypeToken.RESERVED) {
                failWith(ErrCode.HANDLE_TYPE)
            }
            let out = HandleTable.append(ctx, v, tok)
            propagateFrozen(src, out)
            out
    }
}

/** M3 R4.9：frozen 经拆箱传播（盒只读 ⇒ 取出的引用也保持只读）。 */
private func propagateFrozen(src: Int64, out: Int64): Unit {
    if (HandleTable.isFrozen(src)) {
        HandleTable.markFrozen(out)
    }
}

/** 按类型码把 cell 还原成宿主值（14 与 16–19 都走宿主对象引用通道）。 */
private func anyValueOf(code: UInt16, cell: Int64): Any {
    match (code) {
        case 0u16 => cell
        case 1u16 => Float64.fromBits(UInt64(cell))
        case 2u16 => cell != 0
        case 3u16 => ()
        case 4u16 => HandleTable.fetchString(cell)
        case 5u16 => HandleTable.fetchDecimal(cell)
        case 6u16 => HandleTable.fetchDateTime(cell)
        case 7u16 => HandleTable.fetchDuration(cell)
        case 8u16 => HandleTable.fetchRange(cell)
        case 9u16 => HandleTable.fetchRegexEx(cell)
        case 10u16 => HandleTable.fetchList(cell)
        case 11u16 => HandleTable.fetchMap(cell)
        case 14u16 => HandleTable.fetchHostObject(cell)
        case 16u16 => HandleTable.fetchHostObject(cell)
        case 17u16 => HandleTable.fetchHostObject(cell)
        case 18u16 => HandleTable.fetchHostObject(cell)
        case 19u16 => HandleTable.fetchHostObject(cell)
        case _ => failWith(ErrCode.HANDLE_TYPE)
    }
}

/** 盒内容是否匹配「类型码 + aux」（JSON 走码级继承：17/18/19 都是 16 的后代）。 */
private func anyMatches(v: Any, code: UInt16, aux: Int64): Bool {
    match (code) {
        case 0u16 => v is Int64
        case 1u16 => v is Float64
        case 2u16 => v is Bool
        case 3u16 => false
        case 4u16 => v is String
        case 5u16 => v is Decimal
        case 6u16 => v is DateTime
        case 7u16 => v is Duration
        case 8u16 => v is Range<Int64>
        case 9u16 => v is JitRegex
        // 容器：世界内形态恒为 ArrayList<Any> / HashMap<ConstMapKey, Any>，再看 aux
        case 10u16 => v is ArrayList<Any> && listAuxMatches(aux)
        case 11u16 => v is HashMap<ConstMapKey, Any> && mapAuxMatches(aux)
        // 14：宿主对象 + 类界（aux = `$as$<C>` 的 hid；0xFFFF = 兼容口径）
        case 14u16 => v is Object && !(v is JsonValue) &&
            (aux == 0xFFFF || classBoundHit(v, aux))
        case 16u16 => v is JsonValue
        case 17u16 => v is JsonObject
        case 18u16 => v is JsonArray
        case 19u16 => v is JsonNull
        case _ => false
    }
}

/**
 * 14 目标的类界判定（D1）：委托给 `aux` 指向的 `$as$<C>`（注册期合成的 `(14) -> Bool`）。
 *
 * `$as$<C>` 走反射父链 ⇒ 子类实例命中、无关类与向下转型不命中，与非 Any 路径的 `is C`
 * 逐例一致。条目缺失 / 签名不符 / 返回值非 Bool 都按**契约错误 8** 处理（`is` 侧除 8 外
 * 永不失败）；判定体内部抛出的普通异常同样不允许穿透到字节码。
 */
private func classBoundHit(v: Any, aux: Int64): Bool {
    let entry = match (UserHelperTable.find(aux)) {
        case Some(e) => e
        case None => failWith(ErrCode.HANDLE_TYPE)
    }
    if (entry.params.size != 1 || entry.params[0] != LocalType.HOST_OBJECT) {
        failWith(ErrCode.HANDLE_TYPE)
    }
    var r: Any = false
    try {
        r = entry.impl([v])
    } catch (e: HelperFail) {
        throw e
    } catch (_: Exception) {
        failWith(ErrCode.HOST_EXCEPTION)
    }
    match (r) {
        case b: Bool => b
        case _ => failWith(ErrCode.HANDLE_TYPE)
    }
}

/**
 * List 的 `aux` 分派（m3 §5「有限分支表」）：`aux = 元素类型码`。
 *
 * 世界内列表的运行时形态**恒为** `ArrayList<Any>`（`tokenOf` 只认它，其余 RESERVED），
 * 因此只有「元素 = Any」（15）与「未指定」（0xFFFF）两种 aux 能命中——`List<Int64>`
 * 按不变语义**不命中**（design D18）。元素非 Any 的宿主容器根本 pin 不进句柄表，
 * 所以这里不存在「漏判」：能进盒的列表元素一定是盒。
 */
private func listAuxMatches(aux: Int64): Bool {
    aux == Int64(LocalType.ANY) || aux == 0xFFFF
}

/**
 * Map 的 `aux` = `(键码 << 8) | 值码`。
 *
 * 键码被 `ConstMapKey` 包装**擦除**（`Map<Int64,Any>` 与 `Map<String,Any>` 运行时同形），
 * 无法也不应校验；只看值码是否 Any / 未指定。
 */
private func mapAuxMatches(aux: Int64): Bool {
    if (aux == 0xFFFF) {
        return true
    }
    (aux & 0xFF) == Int64(LocalType.ANY)
}

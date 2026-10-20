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

import fountain::f_data.json.{JsonArray, JsonBool, JsonDecimal, JsonInt, JsonNull, JsonObject, JsonString, JsonValue}
import fountain::f_jit.base.ErrCode

/**
 * M3 JSON 世界内可变 API：H81 `json_get` / H82 `json_set` / H83 `json_new`（m3 §11）。
 *
 * `mode`：0 = 对象（键是 String 句柄）、1 = 数组（键是 Int64 下标）。
 *
 * 已知边界：`json_set` 的 `Float64`（码 1）暂以 8 拒绝——`f_data` 的数字节点是 `Decimal`
 * 基底，Float64 的精确十进制化口径未定；其余值域（Int64/Bool/String/JSON 节点）已实现。
 */
internal func jsonGet(ctx: JitContext, a: Array<Int64>): Int64 {
    let unused = ctx
    let _ = unused
    let h = argAt(a, 0)
    let keyCell = argAt(a, 1)
    let mode = UInt8(argAt(a, 2))
    let node = HandleTable.fetchHostObject(h)
    let value = if (mode == 0u8) {
        match (node) {
            case o: JsonObject =>
                let k = HandleTable.fetchString(keyCell)
                match (o.get(k)) {
                    case Some(v) => v
                    case None => failWith(ErrCode.KEY_MISSING)
                }
            case _ => failWith(ErrCode.HANDLE_TYPE)
        }
    } else {
        match (node) {
            case arr: JsonArray =>
                let i = keyCell
                if (i < 0 || i >= arr.size) {
                    failWith(ErrCode.IDX_OOB)
                }
                arr[i]
            case _ => failWith(ErrCode.HANDLE_TYPE)
        }
    }
    let boxed = HandleTable.pinAnyBox(exportJson(value))
    // frozen 经读传播：从只读常量取出的一切子值都保持只读（无需树遍历）
    if (HandleTable.isFrozen(h)) {
        HandleTable.markFrozen(boxed)
    }
    boxed
}

/** H82：`json_set(h16, key, typecode, v) → 0`（变更型；frozen → 20；不登记新槽）。 */
internal func jsonSet(ctx: JitContext, a: Array<Int64>): Int64 {
    let unused = ctx
    let _ = unused
    let h = argAt(a, 0)
    let keyCell = argAt(a, 1)
    let code = UInt16(argAt(a, 2))
    let node = HandleTable.fetchHostObject(h)
    if (HandleTable.isFrozen(h)) {
        failWith(ErrCode.READONLY)
    }
    let jv = jsonValueOf(code, argAt(a, 3))
    match (node) {
        case o: JsonObject =>
            let k = HandleTable.fetchString(keyCell)
            o[k] = jv
        case arr: JsonArray =>
            let i = keyCell
            if (i < 0 || i >= arr.size) {
                failWith(ErrCode.IDX_OOB)
            }
            arr[i] = jv
        case _ => failWith(ErrCode.HANDLE_TYPE)
    }
    0
}

/** H83：`json_new(mode) → h16`（分配型；0 = 对象、1 = 数组；非常量、非 frozen）。 */
internal func jsonNew(ctx: JitContext, a: Array<Int64>): Int64 {
    let unused = ctx
    let _ = unused
    let mode = UInt8(argAt(a, 0))
    let v: JsonValue = if (mode == 0u8) {
        JsonObject()
    } else {
        JsonArray()
    }
    HandleTable.pin(v)
}

/** 出口解包（只在 `json_get` 出口发生）：标量 → 宿主值盒；对象/数组/null → 节点盒。 */
private func exportJson(v: JsonValue): Any {
    match (v) {
        case i: JsonInt =>
            // 域内 → Int64；超域 → Decimal（BigInt 保真）
            try {
                i.toInt64()
            } catch (_: Exception) {
                i.value
            }
        case d: JsonDecimal => d.value
        case s: JsonString => s.value
        case b: JsonBool => b.value
        case n: JsonNull => n
        case other => other
    }
}

/** 写入侧的值域：值型 0–3（Unit/Float64 除外）/ String / JSON 节点。 */
private func jsonValueOf(code: UInt16, cell: Int64): JsonValue {
    match (code) {
        case 0u16 => JsonInt(cell)
        case 2u16 => JsonBool(cell != 0)
        case 4u16 => JsonString(HandleTable.fetchString(cell))
        case 16u16 => asJson(HandleTable.fetchHostObject(cell))
        case 17u16 => asJson(HandleTable.fetchHostObject(cell))
        case 18u16 => asJson(HandleTable.fetchHostObject(cell))
        case 19u16 => asJson(HandleTable.fetchHostObject(cell))
        case _ => failWith(ErrCode.HANDLE_TYPE)
    }
}

private func asJson(o: Object): JsonValue {
    match (o) {
        case j: JsonValue => j
        case _ => failWith(ErrCode.HANDLE_TYPE)
    }
}

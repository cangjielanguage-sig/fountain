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
import std.sync.Mutex
import std.time.DateTime
import fountain::f_jit.base.ErrCode
import fountain::f_jit.base.TypeToken
import fountain::f_jit.bytecode.ConstMapKey

/**
 * H63 `host_call_trampoline`（m2 §5）—— CALL_HOST 的转发器。
 *
 * 执行流（与 user helper 转发同一套 helper 基础设施）：
 *
 * 1. fetch **栈底**句柄 → `HostCallback{fn, sig}`（tag≠10 → 8；未验签/元数不符 → 99）；
 * 2. 逐参 cell → 仓颉值（值型原值 / 句柄型 `get` / 14 实例引用，见 `reflectiveInvoke`）；
 * 3. 用 `FunctionTypeInfo.apply` 调 `fn`（任意元数、零类型分派；可能 GC / 抛异常 / 重入 JIT）；
 * 4. 返回值 → cell：值型原值、引用型登记 1 槽。
 *
 * 失败语义：宿主闭包抛出的任何异常 ⇒ **21 + cause**（fail-fast）；引擎不变式破坏 ⇒ 99。
 * 本函数**绝不把异常抛给字节码/机器码**（由 `invokeHelper` 统一转码写槽）。
 */
internal func hostCallTrampoline(ctx: JitContext, a: Array<Int64>): Int64 {
    // 防御：CALL_HOST 至少携带 h_fn（汇编期 argc+1 保证；命中即引擎缺陷）
    if (a.size <= 0) {
        failWith(ErrCode.HELPER_PANIC)
    }
    let h = a[0]
    if (HandleTable.tagOrZero(h) != TypeToken.HOST_CLOSURE) {
        failWith(ErrCode.HANDLE_TYPE)
    }
    let cb = HandleTable.fetchHostCallback(h)
    let sig = match (cb.sig) {
        case Some(s) => s
        case None => failWith(ErrCode.HELPER_PANIC)
    }
    if (!sig.validate()) {
        failWith(ErrCode.HELPER_PANIC)
    }
    let nargs = a.size - 1
    if (nargs != sig.params.size) {
        failWith(ErrCode.HELPER_PANIC)
    }
    var r: Any = 0
    try {
        // M2.2：登记过同结构类型化 adapter 时**跳过反射**（静态类型调用）；否则维持原路径。
        match (cb.adapter) {
            case Some(ad) => r = ad(cb.fn, convertArgs(sig, a))
            case None => r = reflectiveInvoke(cb.fn, cb.ti, sig, a)
        }
    } catch (e: HelperFail) {
        // 引擎侧失败（绑定/转换）原样转码，不归宿主异常
        throw e
    } catch (e: Exception) {
        HostFault.record(ctx, e)
        failWith(ErrCode.HOST_EXCEPTION)
    }
    hostResultCell(ctx, sig.ret, r)
}

/** 返回值装箱：值型原值、引用型登记 1 槽（R 的引用性编译期已知）。 */
internal func hostResultCell(ctx: JitContext, ret: UInt16, r: Any): Int64 {
    match (ret) {
        case 0u16 => match (r) {
            case v: Int64 => v
            case _ => failWith(ErrCode.HELPER_PANIC)
        }
        case 1u16 => match (r) {
            case v: Float64 => Int64(v.toBits())
            case _ => failWith(ErrCode.HELPER_PANIC)
        }
        case 2u16 => match (r) {
            case v: Bool => if (v) { 1 } else { 0 }
            case _ => failWith(ErrCode.HELPER_PANIC)
        }
        case 3u16 => 0
        case 4u16 => allocHandleResult(ctx, ret, r)
        case 5u16 => allocHandleResult(ctx, ret, r)
        case 6u16 => allocHandleResult(ctx, ret, r)
        case 7u16 => allocHandleResult(ctx, ret, r)
        case 8u16 => allocHandleResult(ctx, ret, r)
        case 9u16 => allocHandleResult(ctx, ret, r)
        case 10u16 => allocHandleResult(ctx, ret, r)
        case 11u16 => allocHandleResult(ctx, ret, r)
        case 13u16 => match (r) {
            case cb: HostCallback => HandleTable.append(ctx, cb, TypeToken.HOST_CLOSURE)
            case _ => failWith(ErrCode.HELPER_PANIC)
        }
        case 14u16 => match (r) {
            case o: Object => HandleTable.append(ctx, o, TypeToken.HOST_OBJECT)
            case _ => failWith(ErrCode.HELPER_PANIC)
        }
        case _ => failWith(ErrCode.HELPER_PANIC)
    }
}

/** 句柄型返回：校验实际类型大类后登记 1 槽（分配型语义）。 */
private func allocHandleResult(ctx: JitContext, ret: UInt16, r: Any): Int64 {
    let want = HostCall.mapToken(ret)
    if (HandleTable.tokenOf(r) != want) {
        failWith(ErrCode.HELPER_PANIC)
    }
    allocValue(ctx, r)
}

/** LocalType → TypeToken 映射（仅句柄型；14 单独走 tag 11）。 */
private class HostCall {
    public static func mapToken(t: UInt16): UInt16 {
        match (t) {
            case 4u16 => TypeToken.STRING
            case 5u16 => TypeToken.DECIMAL
            case 6u16 => TypeToken.DATETIME
            case 7u16 => TypeToken.DURATION
            case 8u16 => TypeToken.RANGE
            case 9u16 => TypeToken.REGEX
            case 10u16 => TypeToken.LIST
            case 11u16 => TypeToken.MAP
            case 14u16 => TypeToken.HOST_OBJECT
            case _ => TypeToken.RESERVED
        }
    }
}

// ============================================================================
// 逐参 cell → 仓颉值
// ============================================================================

internal func asI64(c: Int64): Int64 {
    c
}

internal func asF64(c: Int64): Float64 {
    Float64.fromBits(UInt64(c))
}

internal func asBool(c: Int64): Bool {
    c != 0
}

internal func asUnit(c: Int64): Unit {
    let _ = c
    ()
}

internal func asStr(c: Int64): String {
    HandleTable.fetchString(c)
}

internal func asDec(c: Int64): Decimal {
    HandleTable.fetchDecimal(c)
}

internal func asDt(c: Int64): DateTime {
    HandleTable.fetchDateTime(c)
}

internal func asDur(c: Int64): Duration {
    HandleTable.fetchDuration(c)
}

internal func asRange(c: Int64): Range<Int64> {
    HandleTable.fetchRange(c)
}

internal func asList(c: Int64): ArrayList<Any> {
    HandleTable.fetchList(c)
}

internal func asMap(c: Int64): HashMap<ConstMapKey, Any> {
    HandleTable.fetchMap(c)
}

internal func asObj(c: Int64): Object {
    HandleTable.fetchHostObject(c)
}

/**
 * 宿主异常 cause 通道（**调用私有**）。
 *
 * ctx 布局冻结（64 B 无 cause 字段），故按 ctx 地址做调用级旁路：记录原始异常全文
 * （message + causedBy 链）与异常对象（桥可据此 `printStackTrace` 打印完整仓颉栈）。
 * 条目随 `takeCause`/`clear` 销毁，不跨调用、不跨线程共享。
 */
public class HostFault {
    private static let mtx = Mutex()
    private static let texts = HashMap<UInt64, String>()
    private static let exceptions = HashMap<UInt64, Exception>()

    private static func keyOf(ctx: JitContext): UInt64 {
        UInt64(ctx.cp().toUIntNative())
    }

    /** 记录一次宿主异常（后写覆盖——同一调用内最后一次失败为准）。 */
    public static func record(ctx: JitContext, e: Exception): Unit {
        let k = HostFault.keyOf(ctx)
        synchronized(mtx) {
            texts.add(k, HostFault.describe(e))
            exceptions.add(k, e)
        }
    }

    /** 读取 cause 文本（不销毁；供断言/诊断）。 */
    public static func causeOf(ctx: JitContext): ?String {
        let k = HostFault.keyOf(ctx)
        synchronized(mtx) {
            texts.get(k)
        }
    }

    /** 读取原始异常对象（不销毁；桥据此打印完整栈）。 */
    public static func exceptionOf(ctx: JitContext): ?Exception {
        let k = HostFault.keyOf(ctx)
        synchronized(mtx) {
            exceptions.get(k)
        }
    }

    /** 取走 cause 文本并清空本次调用的记录（桥构造 `JitException` 时调用）。 */
    public static func takeCause(ctx: JitContext): ?String {
        let k = HostFault.keyOf(ctx)
        synchronized(mtx) {
            let v = texts.get(k)
            texts.remove(k)
            exceptions.remove(k)
            v
        }
    }

    /** 清空本次调用的记录（无 cause 的文件收尾/测试复位）。 */
    public static func clear(ctx: JitContext): Unit {
        let k = HostFault.keyOf(ctx)
        synchronized(mtx) {
            texts.remove(k)
            exceptions.remove(k)
        }
    }

    /** 异常全文：`toString` + `causedBy` 链 + **完整仓颉异常栈**（帧序 = 抛出点在前）。 */
    private static func describe(e: Exception): String {
        var s = HostFault.describeOne(e)
        var cur = e.causedBy
        var depth = 0
        while (depth < 8) {
            match (cur) {
                case Some(inner) =>
                    s = s + '\nCaused by: ' + HostFault.describeOne(inner)
                    cur = inner.causedBy
                case None => break
            }
            depth = depth + 1
        }
        s
    }

    /** 单个异常的文本 + 栈帧（`at Class.method(file:line)`，逐帧一行、顺序保持）。 */
    private static func describeOne(e: Exception): String {
        var s = e.toString()
        for (frame in e.getStackTrace()) {
            s = s + '\n    at ${frame.declaringClass}.${frame.methodName}' +
                '(${frame.fileName}: ${frame.lineNumber})'
        }
        s
    }
}

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
import std.collection.ConcurrentModificationException
import std.collection.HashMap
import std.sync.Mutex
import fountain::f_jit.base.ErrCode
import fountain::f_jit.base.TypeToken
import fountain::f_jit.bytecode.CanonKey
import fountain::f_jit.bytecode.ConstMapKey

/**
 * 调用级 Map 迭代器表 —— design-m1 §5.3.3、plan-m1 S4.6。
 *
 * 权威 = `doc/jit-bytecode-m1.md` §11.9 迭代语义② + v0.18.35 实施注记：
 *
 * - 游标 = **调用级迭代器表索引**，编码为 `(gen << 32) | idx`（`gen` 防陈旧游标：DEOPT 重放后
 *   旧游标一律失效 ⇒ 99 防御）；
 * - 表项 = **类型化迭代工厂**（`open/next/key/value` 四件套的封装，H49/H62 实现体因此类型无关）
 *   + 相位标记（未推进取件 → 99）+ close 标记（幂等）；
 * - 表在**调用结束与 DEOPT 交接两点清空**；
 * - **不占用句柄窗口**（记账零新增），条目数 ≤ 嵌套深度。
 */
public class IterTable {
    private static let entries: ArrayList<?IterEntry> = ArrayList<?IterEntry>()
    private static let gens: ArrayList<UInt32> = ArrayList<UInt32>()
    /** 表状态锁（A5/P2-2b）：桥调用虽串行，但宿主多线程可直接调 H49/H62。 */
    private static let mtx = Mutex()

    /**
     * 建立迭代器（H49 `map_iter_begin`）。
     *
     * `h` 为 Map 句柄（null → 6、类型不符 → 8）；返回游标 `(gen << 32) | idx`。
     */
    public static func open(h: Int64, elementKind: UInt8): Int64 {
        let m = HandleTable.fetchMap(h)
        synchronized(mtx) {
            let e = IterEntry(h, m)
            let idx = entries.size
            entries.add(Some(e))
            gens.add(1u32)
            makeCursor(idx, 1u32)
        }
    }

    /** 推进（mode 0）：返回 0/1 —— **终止判定的唯一来源**（1 = 已推进至有效条目）。 */
    public static func next(cur: Int64): Bool {
        synchronized(mtx) {
            entryOf(cur).advance()
        }
    }

    /** 取键（mode 1）：未推进 / 已关闭 ⇒ 99 防御。 */
    public static func key(cur: Int64): Int64 {
        synchronized(mtx) {
            entryOf(cur).keyCellLocked()
        }
    }

    /** 取值（mode 2）：未推进 / 已关闭 ⇒ 99 防御。 */
    public static func value(cur: Int64): Int64 {
        synchronized(mtx) {
            entryOf(cur).valueCellLocked()
        }
    }

    /** 关闭（mode 3）：幂等。 */
    public static func close(cur: Int64): Unit {
        let idx = idxOfCursor(cur)
        if (idx < 0) {
            return
        }
        synchronized(mtx) {
            if (idx >= entries.size) {
                return
            }
            match (entries[idx]) {
                case Some(e) =>
                    if (gens[idx] == genOfCursor(cur)) {
                        e.close()
                    }
                case None => ()
            }
        }
    }

    /** 调用结束与 DEOPT 交接两点清空（旧游标一律失效 ⇒ 99）。 */
    public static func clearAll(): Unit {
        synchronized(mtx) {
            entries.clear()
            gens.clear()
        }
    }

    /** 当前活跃条目数（≤ 嵌套深度；审计用）。 */
    public static func liveCount(): Int64 {
        synchronized(mtx) {
            var n = 0
            for (i in 0..entries.size) {
                match (entries[i]) {
                    case Some(e) => if (!e.closed) { n = n + 1 }
                    case None => ()
                }
            }
            n
        }
    }

    // ---- 游标编解码 ----

    public static func makeCursor(idx: Int64, gen: UInt32): Int64 {
        Int64((UInt64(gen) << 32) | UInt64(UInt32(idx)))
    }

    public static func idxOfCursor(cur: Int64): Int64 {
        if (cur <= 0) {
            -1
        } else {
            Int64(UInt64(cur) & 0x00000000FFFFFFFFu64)
        }
    }

    public static func genOfCursor(cur: Int64): UInt32 {
        if (cur <= 0) {
            0u32
        } else {
            UInt32((UInt64(cur) >> 32) & 0xFFFFFFFFu64)
        }
    }

    private static func entryOf(cur: Int64): IterEntry {
        let idx = idxOfCursor(cur)
        if (idx < 0 || idx >= entries.size) {
            failWith(ErrCode.HELPER_PANIC)
        }
        match (entries[idx]) {
            case Some(e) =>
                if (gens[idx] != genOfCursor(cur)) {
                    failWith(ErrCode.HELPER_PANIC)
                }
                e
            case None => failWith(ErrCode.HELPER_PANIC)
        }
    }
}

/** 迭代器表项：持有 Map 的宿主迭代器 + 相位 / 关闭标记。 */
internal class IterEntry {
    private let mapHandle: Int64
    private let iter: Iterator<(ConstMapKey, Any)>
    private var advanced: Bool = false
    private var closedFlag: Bool = false
    private var curKey: Int64 = 0
    private var curValue: Int64 = 0

    internal init(mapHandle: Int64, m: HashMap<ConstMapKey, Any>) {
        this.mapHandle = mapHandle
        this.iter = m.iterator()
    }

    internal prop closed: Bool {
        get() {
            this.closedFlag
        }
    }

    /**
     * 推进一项。std 的 `HashMap.iterator()` 是 fail-fast 的：迭代期间修改**同一** map 会在推进
     * 时抛 `ConcurrentModificationException` ⇒ 转码为 **23**（§11.9 迭代语义②）。
     */
    internal func advance(): Bool {
        if (this.closedFlag) {
            failWith(ErrCode.HELPER_PANIC)
        }
        var got: ?(ConstMapKey, Any) = None
        try {
            got = this.iter.next()
        } catch (e: ConcurrentModificationException) {
            failWith(ErrCode.CONCURRENT_MOD)
        } catch (e: Exception) {
            failWith(ErrCode.HELPER_PANIC)
        }
        match (got) {
            case Some(kv) =>
                this.curKey = HandleTable.anyToCell(kv[0].value)
                this.curValue = HandleTable.anyToCell(kv[1])
                this.advanced = true
                true
            case None =>
                this.advanced = false
                false
        }
    }

    internal func keyCellLocked(): Int64 {
        if (this.closedFlag || !this.advanced) {
            failWith(ErrCode.HELPER_PANIC)
        }
        this.curKey
    }

    internal func valueCellLocked(): Int64 {
        if (this.closedFlag || !this.advanced) {
            failWith(ErrCode.HELPER_PANIC)
        }
        this.curValue
    }

    internal func close(): Unit {
        this.closedFlag = true
        this.advanced = false
    }
}

/**
 * 把宿主 Map 的键 cell 规范成 `ConstMapKey`（运行时写键与常量键共用同一键空间）。
 *
 * 键的规范文本按「活句柄 ⇒ 对象规范键；否则 ⇒ 整数原值」生成，保证**等值键必命中同一条目**、
 * 不同值必得不同 token。
 */
internal func mapKeyOf(cell: Int64): ConstMapKey {
    match (HandleTable.getAny(cell)) {
        case Some(v) => ConstMapKey(v, HandleTable.canonKeyOf(v))
        case None => ConstMapKey(cell, CanonKey.cell(cell))
    }
}

/** 由键 cell 构造 Map 条目（运行时 `MAP_PUT` 用）。 */
internal func makeRuntimeMap(): HashMap<ConstMapKey, Any> {
    HashMap<ConstMapKey, Any>()
}

/** 空 List 构造（H70；分配型，可变）。 */
internal func makeRuntimeList(): ArrayList<Any> {
    ArrayList<Any>()
}

/** `TypeToken` → 是否容器（List / Map）。 */
internal func isContainerToken(tok: UInt16): Bool {
    tok == TypeToken.LIST || tok == TypeToken.MAP
}

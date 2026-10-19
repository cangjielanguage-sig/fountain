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
package fountain::f_jit.bytecode

import std.collection.ArrayList
import fountain::f_base.UnsafeBytes

/**
 * 变量名表 —— design-m1 §3.3.7、plan-m1 S2.10。
 *
 * 权威 = `doc/jit-bytecode-m1.md` §11.6（name 段序列化，v0.18.25 冻结）与 §11.7：
 *
 * ```
 * NameTable  { count: u32, entries: [NameEntry], strBytes: [u8] }
 * NameEntry  = (fnId: u32, slot: u32, strOff: u32, strLen: u32)     // 恒 16 B
 * ```
 *
 * - `strOff` 相对 `strBytes` 区起点，`strBytes` 紧接 `entries` 之后；
 * - `(fnId, slot)` **升序、键唯一**；名字 = 源码标识符的 UTF-8 字节；
 * - `nameLen = 4 + 16 × count + strBytes 长度`（段恒存在，`count` 可为 0）；
 * - **稀疏**：只登记源码级命名槽（参数 / `for` 迭代变量 / 赋值·声明目标），编译器引入的隐藏槽
 *   （多重赋值暂存、容器·映射迭代的索引·长度·迭代器状态、`recursive` 值化适配器、闭包帧
 *   `locals[0]`）**不登记**；查询未命中 → 报告省略名字（§11.6、§11.7）。
 */
public struct NameEntry {
    /** 函数号（须命中目录）。 */
    public let fnId: UInt32
    /** 槽位序号（须 < 该函数 `nLocals`）。 */
    public let slot: UInt32
    /** 相对 `strBytes` 区起点的字节偏移（段内相对偏移，§11.6）。 */
    public let strOff: UInt32
    /** 名字字节长度（≥ 1）。 */
    public let strLen: UInt32

    public init(fnId: UInt32, slot: UInt32, strOff: UInt32, strLen: UInt32) {
        this.fnId = fnId
        this.slot = slot
        this.strOff = strOff
        this.strLen = strLen
    }

    /** 条目定长（§11.6「恒 16 B」）。 */
    public static const SIZE: Int64 = 16

    /** 按 §11.6 写出 16 字节。 */
    public func write(w: ByteWriter): Unit {
        w.wU32(this.fnId)
        w.wU32(this.slot)
        w.wU32(this.strOff)
        w.wU32(this.strLen)
    }

    /** 按同一顺序读回 16 字节。 */
    public static func read(r: ByteReader): NameEntry {
        let fnId = r.u32()
        let slot = r.u32()
        let strOff = r.u32()
        let strLen = r.u32()
        NameEntry(fnId, slot, strOff, strLen)
    }

    /** 键序比较：先 `fnId`、后 `slot`（§11.6「(fnId, slot) 升序、键唯一」）。 */
    public static func keyLess(a: NameEntry, b: NameEntry): Bool {
        if (a.fnId != b.fnId) {
            a.fnId < b.fnId
        } else {
            a.slot < b.slot
        }
    }
}

public class NameTable {
    private let entries: ArrayList<NameEntry>
    private let strBytes: ArrayList<UInt8>
    private var frozenFlag: Bool

    public init() {
        this.entries = ArrayList<NameEntry>()
        this.strBytes = ArrayList<UInt8>()
        this.frozenFlag = false
    }

    public prop size: Int64 {
        get() {
            this.entries.size
        }
    }

    public prop isFrozen: Bool {
        get() {
            this.frozenFlag
        }
    }

    /** `strBytes` 区长度（段长计算：`4 + 16 × count + strBytes`）。 */
    public prop strBytesSize: Int64 {
        get() {
            this.strBytes.size
        }
    }

    public func at(i: Int64): NameEntry {
        if (i < 0 || i >= this.entries.size) {
            rejectFormat('名字表下标越界: ${i} / ${this.entries.size}')
        }
        this.entries[i]
    }

    /**
     * 登记一个源码级命名槽（键必须**严格升序**）。
     *
     * 名字字节被追加到 `strBytes` 区尾部；`strOff` 即追加前的位置（§11.6）。
     */
    public func add(fnId: UInt32, slot: UInt32, name: String): Unit {
        if (this.frozenFlag) {
            rejectFormat('名字表已冻结，拒绝写入')
        }
        let bs = name.unsafeBytes()
        if (bs.size == 0) {
            rejectFormat('变量名为空（§11.6「strLen ≥ 1」）')
        }
        let e = NameEntry(fnId, slot, UInt32(this.strBytes.size), UInt32(bs.size))
        if (this.entries.size > 0 && !NameEntry.keyLess(this.entries[this.entries.size - 1], e)) {
            rejectFormat('名字表键未严格升序或重复: fnId=${fnId}, slot=${slot}（§11.6）')
        }
        this.entries.add(e)
        for (b in bs) {
            this.strBytes.add(b)
        }
    }

    public func freeze(): Unit {
        this.frozenFlag = true
    }

    /** 稀疏查询（二分）；未命中 ⇒ `None`（报告省略名字）。 */
    public func lookup(fnId: UInt32, slot: UInt32): ?String {
        let key = NameEntry(fnId, slot, 0u32, 0u32)
        var lo = 0
        var hi = this.entries.size
        while (lo < hi) {
            let mid = lo + (hi - lo) / 2
            let m = this.entries[mid]
            if (m.fnId == fnId && m.slot == slot) {
                return Some(nameAt(m))
            } else if (NameEntry.keyLess(m, key)) {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        None
    }

    private func nameAt(e: NameEntry): String {
        let start = Int64(e.strOff)
        let end = start + Int64(e.strLen)
        let bs = Array<UInt8>(Int64(e.strLen), repeat: 0u8)
        for (i in start..end) {
            bs[i - start] = this.strBytes[i]
        }
        String.fromUtf8(bs)
    }

    /**
     * 加载期校验（§11.6）：`fnId` 命中目录、`slot <` 该函数 `nLocals`、`(fnId, slot)` 严格升序
     * 唯一、`strLen ≥ 1`、`strOff + strLen ≤ strBytes 长度`、UTF-8 合法。
     */
    public func validate(dir: FuncDir, types: Array<LocalTypes>): Unit {
        let limit = Int64(this.strBytes.size)
        for (i in 0..this.entries.size) {
            let e = this.entries[i]
            if (i > 0 && !NameEntry.keyLess(this.entries[i - 1], e)) {
                rejectFormat('名字表键未严格升序或重复: fnId=${e.fnId}, slot=${e.slot}（§11.6）')
            }
            let fn = dir.get(e.fnId)
            // 类型表按目录顺序与函数一一对应
            var nLocals = 0
            for (k in 0..dir.size) {
                if (dir.at(k).fnId == e.fnId) {
                    nLocals = types[k].size
                    break
                }
            }
            if (Int64(e.slot) >= nLocals) {
                rejectFormat(
                    '名字表槽位越界: fnId=${e.fnId}, slot=${e.slot}, nLocals=${nLocals}（§11.6「slot < nLocals」）')
            }
            if (e.strLen < 1u32) {
                rejectFormat('变量名为空: fnId=${e.fnId}, slot=${e.slot}（§11.6「strLen ≥ 1」）')
            }
            if (Int64(e.strOff) + Int64(e.strLen) > limit) {
                rejectFormat('名字字节越界: fnId=${e.fnId}, slot=${e.slot}, strOff=${e.strOff}, strLen=${e.strLen}')
            }
            // UTF-8 合法（§11.6）
            try {
                nameAt(e)
            } catch (ex: Exception) {
                rejectFormat('变量名非合法 UTF-8: fnId=${e.fnId}, slot=${e.slot}（§11.6）')
            }
            let unused = fn.fnId // fnId 命中目录（未命中时 dir.get 已拒绝）
            let _ = unused
        }
    }

    /** 编码 name 段：`count: u32 + 16 B × count + strBytes`（§11.6）。 */
    public func encode(): Array<UInt8> {
        let w = ByteWriter()
        w.wU32(UInt32(this.entries.size))
        for (e in this.entries) {
            e.write(w)
        }
        w.wBytes(this.strBytes.toArray())
        w.take()
    }

    /** 解码 name 段并冻结；坏键 / 越界 / 非法 UTF-8 ⇒ 容器格式类拒绝。 */
    public static func decode(bytes: Array<UInt8>): NameTable {
        let t = NameTable()
        let r = ByteReader(bytes)
        let count = r.u32()
        if (Int64(count) * NameEntry.SIZE > r.remaining()) {
            rejectFormat('name 段条目数与字节数不符: count=${count}, 剩余=${r.remaining()}')
        }
        for (_ in 0..Int64(count)) {
            let e = NameEntry.read(r)
            if (t.entries.size > 0 && !NameEntry.keyLess(t.entries[t.entries.size - 1], e)) {
                rejectFormat('名字表键未严格升序或重复: fnId=${e.fnId}, slot=${e.slot}（§11.6）')
            }
            if (e.strLen < 1u32) {
                rejectFormat('变量名为空: fnId=${e.fnId}, slot=${e.slot}（§11.6「strLen ≥ 1」）')
            }
            t.entries.add(e)
        }
        let rest = r.remaining()
        for (_ in 0..rest) {
            t.strBytes.add(r.u8())
        }
        for (e in t.entries) {
            if (Int64(e.strOff) + Int64(e.strLen) > t.strBytes.size) {
                rejectFormat('名字字节越界: fnId=${e.fnId}, slot=${e.slot}, strOff=${e.strOff}, strLen=${e.strLen}')
            }
            try {
                t.nameAt(e)
            } catch (ex: Exception) {
                rejectFormat('变量名非合法 UTF-8: fnId=${e.fnId}, slot=${e.slot}（§11.6）')
            }
        }
        t.freeze()
        t
    }
}

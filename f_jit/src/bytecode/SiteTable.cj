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
import fountain::f_jit.base.SourcePos

/**
 * 站点表 —— design-m1 §3.3.7、plan-m1 S2.9。
 *
 * 权威 = `doc/jit-bytecode-m1.md` §11.6（site 段序列化，v0.18.23 冻结）与 §9.16：
 *
 * ```
 * SiteTable  { count: u32, entries: [SiteEntry] }
 * SiteEntry  = (off: u32, line: u32, column: u32)       // 恒 12 B
 * ```
 *
 * - `off` = site 生效位置在 **code 段的绝对字节偏移**（含函数 `codeOff` 基准），**升序、唯一**；
 * - `line` / `column` **1 起**，列按 Unicode 码点（与 §8.2 `SourcePos` 同定义）；
 * - 查询 = 取 `off ≤ site` 的**最大条目**；无命中 → `sourcePos = None`；
 * - 站点表是**平台无关的偏移 → 源位置映射**，三引擎的错误报告都从这里取源位置（§11.6）。
 *
 * 用**升序数组 + 二分**承载（design-m1 §3.3.7）：查询是「取不超过给定值的最大键」，升序数组
 * 的二分查找是唯一既 O(log n) 又无额外结构的选择。
 */

/** 站点条目，恒 12 B（struct：纯值、无身份）。 */
public struct SiteEntry {
    /** code 段绝对字节偏移（含函数 `codeOff` 基准）。 */
    public let off: UInt32
    /** 1 起。 */
    public let line: UInt32
    /** 1 起，按 Unicode 码点计。 */
    public let column: UInt32

    public init(off: UInt32, line: UInt32, column: UInt32) {
        this.off = off
        this.line = line
        this.column = column
    }

    /** 条目定长（§11.6「恒 12 B」）。 */
    public static const SIZE: Int64 = 12

    /** 按 §11.6 写出 12 字节。 */
    public func write(w: ByteWriter): Unit {
        w.wU32(this.off)
        w.wU32(this.line)
        w.wU32(this.column)
    }

    /** 按同一顺序读回 12 字节。 */
    public static func read(r: ByteReader): SiteEntry {
        let off = r.u32()
        let line = r.u32()
        let column = r.u32()
        SiteEntry(off, line, column)
    }
}

public class SiteTable {
    private let entries: ArrayList<SiteEntry>
    private var frozenFlag: Bool

    public init() {
        this.entries = ArrayList<SiteEntry>()
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

    /** 按下标取条目（序列化 / 覆盖率比对用）。 */
    public func at(i: Int64): SiteEntry {
        if (i < 0 || i >= this.entries.size) {
            rejectFormat('站点表下标越界: ${i} / ${this.entries.size}')
        }
        this.entries[i]
    }

    /**
     * 登记一条站点（`off` 必须**严格递增**——§11.6「升序、唯一」）。
     *
     * 前端义务：条目集合必须覆盖**全部 `SET_SITE` 位置**（§11.6 覆盖率），加载器另行校验。
     */
    public func add(off: UInt32, pos: SourcePos): Unit {
        if (this.frozenFlag) {
            rejectFormat('站点表已冻结，拒绝写入')
        }
        if (this.entries.size > 0 && off <= this.entries[this.entries.size - 1].off) {
            rejectFormat('站点表未严格升序: off=${off}（§11.6「升序、唯一」）')
        }
        this.entries.add(SiteEntry(off, UInt32(pos.line), UInt32(pos.column)))
    }

    public func freeze(): Unit {
        this.frozenFlag = true
    }

    /**
     * 取 `off ≤ site` 的**最大条目**；无任何命中 ⇒ `None`（§9.16「无命中 → `sourcePos=None`」）。
     *
     * 二分查找：升序数组的「上界前驱」查询，O(log n)。
     */
    public func lookup(site: Int64): ?SourcePos {
        var lo = 0
        var hi = this.entries.size // 半开区间
        while (lo < hi) {
            let mid = lo + (hi - lo) / 2
            if (Int64(this.entries[mid].off) <= site) {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        if (lo == 0) {
            None
        } else {
            let e = this.entries[lo - 1]
            Some(SourcePos(Int64(e.line), Int64(e.column)))
        }
    }

    /** 该偏移是否恰好命中一条站点条目（覆盖率校验用）。 */
    public func hasExact(off: Int64): Bool {
        var lo = 0
        var hi = this.entries.size
        while (lo < hi) {
            let mid = lo + (hi - lo) / 2
            let v = Int64(this.entries[mid].off)
            if (v == off) {
                return true
            } else if (v < off) {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        false
    }

    /**
     * 加载期校验（§11.6）：`count > 0` 时**严格升序**、`off < codeLen`、`line ≥ 1`、`column ≥ 1`。
     */
    public func validate(codeLen: UInt32): Unit {
        for (i in 0..this.entries.size) {
            let e = this.entries[i]
            if (i > 0 && e.off <= this.entries[i - 1].off) {
                rejectFormat('站点表未严格升序: 第 ${i} 条 off=${e.off}（§11.6）')
            }
            if (e.off >= codeLen) {
                rejectFormat('站点偏移越界: off=${e.off}, codeLen=${codeLen}（§11.6「off < codeLen」）')
            }
            if (e.line < 1u32) {
                rejectFormat('站点行号非法: line=${e.line}（§11.6「line ≥ 1」）')
            }
            if (e.column < 1u32) {
                rejectFormat('站点列号非法: column=${e.column}（§11.6「column ≥ 1」）')
            }
        }
    }

    /** 编码 site 段：`count: u32 + 12 B × count`（§11.6）。 */
    public func encode(): Array<UInt8> {
        let w = ByteWriter()
        w.wU32(UInt32(this.entries.size))
        for (e in this.entries) {
            e.write(w)
        }
        w.take()
    }

    /** 解码 site 段并冻结；乱序 / 段长不符 ⇒ 容器格式类拒绝。 */
    public static func decode(bytes: Array<UInt8>): SiteTable {
        let t = SiteTable()
        let r = ByteReader(bytes)
        let count = r.u32()
        if (Int64(count) * SiteEntry.SIZE > r.remaining()) {
            rejectFormat('site 段条目数与字节数不符: count=${count}, 剩余=${r.remaining()}')
        }
        for (_ in 0..Int64(count)) {
            let e = SiteEntry.read(r)
            if (t.entries.size > 0 && e.off <= t.entries[t.entries.size - 1].off) {
                rejectFormat('站点表未严格升序: off=${e.off}（§11.6）')
            }
            t.entries.add(e)
        }
        if (r.remaining() != 0) {
            rejectFormat('site 段尾部残留字节: ${r.remaining()}')
        }
        t.freeze()
        t
    }
}

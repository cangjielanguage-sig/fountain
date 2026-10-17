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

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_jit.base.*

/**
 * S2.9 `SiteEntry` / `SiteTable` 的失败用例（先写红）。
 *
 * 权威 = `doc/jit-bytecode-m1.md` §11.6：
 *
 * > **site 段序列化（v0.18.23 冻结）**：`SiteTable { count: u32, entries: [SiteEntry] }`，
 * > `SiteEntry = (off: u32, line: u32, column: u32)`（恒 12 B）——`off` = site 生效位置在
 * > **code 段的绝对字节偏移**（含函数 `codeOff` 基准），**升序、唯一**；`line` / `column` 1 起。
 * > 查询 = 取 `off ≤ site` 的最大条目；无命中 → `sourcePos = None`（§9.16）。
 */
@Test
public class SiteTable_test {
    /** 条目恒 12 B，编解码字段保真（§11.6）。 */
    @TestCase
    public func entryIsTwelveBytes(): Unit {
        let e = SiteEntry(100u32, 12u32, 34u32)
        @Assert(SiteEntry.SIZE, 12)
        let w = ByteWriter()
        e.write(w)
        let bs = w.take()
        @Assert(bs.size, 12)
        let r = ByteReader(bs)
        @Assert(r.u32(), 100u32)
        @Assert(r.u32(), 12u32)
        @Assert(r.u32(), 34u32)
        let back = SiteEntry.read(ByteReader(bs))
        @Assert(back.off, e.off)
        @Assert(back.line, e.line)
        @Assert(back.column, e.column)
    }

    /** `lookup` 取 `off ≤ site` 的最大条目；无命中返回 `None`（§11.6 查询定义）。 */
    @TestCase
    public func lookupTakesGreatestEntryAtOrBelowSite(): Unit {
        let t = SiteTable()
        t.add(0u32, SourcePos(1, 1))
        t.add(10u32, SourcePos(2, 5))
        t.add(20u32, SourcePos(3, 9))
        t.freeze()
        @Assert(t.size, 3)

        match (t.lookup(0)) {
            case Some(p) =>
                @Assert(p.line, 1)
                @Assert(p.column, 1)
            case None => @Assert(0, 1)
        }
        match (t.lookup(9)) {
            case Some(p) => @Assert(p.line, 1)
            case None => @Assert(0, 1)
        }
        match (t.lookup(10)) {
            case Some(p) =>
                @Assert(p.line, 2)
                @Assert(p.column, 5)
            case None => @Assert(0, 1)
        }
        match (t.lookup(19)) {
            case Some(p) => @Assert(p.line, 2)
            case None => @Assert(0, 1)
        }
        match (t.lookup(1000)) {
            case Some(p) => @Assert(p.line, 3)
            case None => @Assert(0, 1)
        }
        // site < 首条目 off ⇒ 无命中
        @Assert(t.lookup(-1).isNone(), true)
    }

    /** 段编解码往返（count + 12 B × count）。 */
    @TestCase
    public func sectionRoundTrips(): Unit {
        let t = SiteTable()
        t.add(0u32, SourcePos(1, 1))
        t.add(5u32, SourcePos(2, 3))
        t.freeze()
        let bs = t.encode()
        @Assert(bs.size, 4 + 24)
        let back = SiteTable.decode(bs)
        @Assert(back.size, 2)
        @Assert(back.isFrozen, true)
        match (back.lookup(5)) {
            case Some(p) =>
                @Assert(p.line, 2)
                @Assert(p.column, 3)
            case None => @Assert(0, 1)
        }
    }

    /** 乱序（非严格升序）⇒ 加载期拒绝（§11.6「严格升序」）。 */
    @TestCase
    public func unorderedEntriesAreRejected(): Unit {
        // 手工构造乱序段
        let w = ByteWriter()
        w.wU32(2u32)
        w.wU32(20u32)
        w.wU32(1u32)
        w.wU32(1u32)
        w.wU32(10u32)
        w.wU32(2u32)
        w.wU32(1u32)
        var rejected = false
        try {
            SiteTable.decode(w.take())
        } catch (ex: JitException) {
            @Assert(ex.code, ErrCode.NOT_IMPL)
            rejected = true
        }
        @Assert(rejected, true)
    }

    /** `off >= codeLen` ⇒ 拒绝；`line` / `column` 为 0 ⇒ 拒绝（§11.6 加载器校验）。 */
    @TestCase
    public func outOfRangeAndZeroPositionAreRejected(): Unit {
        var rejected = 0
        // 段自身不携带 codeLen ⇒ 由 validate(codeLen) 校验（加载器传入容器头的 codeLen）
        try {
            oneEntryTable(100u32, 1u32, 1u32).validate(50u32)
        } catch (ex: JitException) {
            rejected = rejected + 1
        }
        try {
            oneEntryTable(0u32, 0u32, 1u32).validate(50u32)
        } catch (ex: JitException) {
            rejected = rejected + 1
        }
        try {
            oneEntryTable(0u32, 1u32, 0u32).validate(50u32)
        } catch (ex: JitException) {
            rejected = rejected + 1
        }
        @Assert(rejected, 3)
        // 正向对照
        oneEntryTable(0u32, 1u32, 1u32).validate(50u32)
    }

    /** 冻结后写入拒绝（前端义务边界：表结构随产物冻结）。 */
    @TestCase
    public func frozenTableRejectsAdd(): Unit {

        let t = SiteTable()
        t.add(0u32, SourcePos(1, 1))
        t.freeze()
        var rejected = false
        try {
            t.add(1u32, SourcePos(1, 2))
        } catch (ex: JitException) {
            rejected = true
        }
        @Assert(rejected, true)
        @Assert(t.size, 1)
    }

    /** 测试夹具：构造只含一条 `SiteEntry` 的站点表。 */
    private func oneEntryTable(off: UInt32, line: UInt32, column: UInt32): SiteTable {
        let w = ByteWriter()
        w.wU32(1u32)
        w.wU32(off)
        w.wU32(line)
        w.wU32(column)
        SiteTable.decode(w.take())
    }
}

/**
 * S2.10 `NameEntry` / `NameTable` 的失败用例（先写红）。
 *
 * 权威 = `doc/jit-bytecode-m1.md` §11.6：
 *
 * > **name 段序列化（v0.18.25 冻结）**：`NameTable { count: u32, entries: [NameEntry], strBytes: [u8] }`，
 * > `NameEntry = (fnId: u32, slot: u32, strOff: u32, strLen: u32)`（恒 16 B；`strOff` 相对
 * > `strBytes` 区起点）；`(fnId, slot)` 升序、键唯一；`nameLen = 4 + 16 × count + strBytes 长度`。
 * > 查询未命中 → 报告省略名字（§9.16）。
 */
@Test
public class NameTable_test {
    /** 条目恒 16 B；段长 = 4 + 16×count + strBytes。 */
    @TestCase
    public func entryIsSixteenBytes(): Unit {
        let e = NameEntry(1u32, 2u32, 0u32, 3u32)
        @Assert(NameEntry.SIZE, 16)
        let w = ByteWriter()
        e.write(w)
        @Assert(w.take().size, 16)

        let t = NameTable()
        t.add(0u32, 0u32, 'ab')
        t.add(0u32, 1u32, 'cde')
        t.freeze()
        let bs = t.encode()
        @Assert(bs.size, 4 + 32 + 5)
        let back = NameTable.decode(bs)
        @Assert(back.size, 2)
        match (back.lookup(0u32, 0u32)) {
            case Some(n) => @Assert(n, 'ab')
            case None => @Assert(0, 1)
        }
        match (back.lookup(0u32, 1u32)) {
            case Some(n) => @Assert(n, 'cde')
            case None => @Assert(0, 1)
        }
    }

    /** `lookup` 未命中返回 `None`（稀疏登记；未命中 ⇒ 报告省略名字，§11.7）。 */
    @TestCase
    public func lookupMissReturnsNone(): Unit {
        let t = NameTable()
        t.add(0u32, 1u32, 'x')
        t.freeze()
        @Assert(t.lookup(0u32, 0u32).isNone(), true)
        @Assert(t.lookup(1u32, 1u32).isNone(), true)
        @Assert(t.lookup(0u32, 1u32).isSome(), true)
    }

    /** 坏键：`fnId` 不命中目录 ⇒ 拒绝。 */
    @TestCase
    public func unknownFnIdIsRejected(): Unit {
        let dir = FuncDir()
        dir.add(FuncEntry(0u32, 30u32, 10u32, 40u32, 0u16, 2u16, 1u16, LocalType.I64, 0u16))
        let types = [LocalTypes(2)]

        let t = NameTable()
        t.add(9u32, 0u32, 'x')
        t.freeze()
        var rejected = false
        try {
            t.validate(dir, types)
        } catch (ex: JitException) {
            @Assert(ex.code, ErrCode.NOT_IMPL)
            rejected = true
        }
        @Assert(rejected, true)
    }

    /** 坏键：`slot >= nLocals` ⇒ 拒绝（§11.6「slot < 该函数 nLocals」）。 */
    @TestCase
    public func slotBeyondNLocalsIsRejected(): Unit {
        let dir = FuncDir()
        dir.add(FuncEntry(0u32, 30u32, 10u32, 40u32, 0u16, 2u16, 1u16, LocalType.I64, 0u16))
        let types = [LocalTypes(2)]

        let t = NameTable()
        t.add(0u32, 5u32, 'x')
        t.freeze()
        var rejected = false
        try {
            t.validate(dir, types)
        } catch (ex: JitException) {
            rejected = true
        }
        @Assert(rejected, true)
    }

    /** 坏键：(fnId, slot) 未升序（`add` 阶段即拒绝，§11.6「升序、键唯一」）。 */
    @TestCase
    public func nonAscendingKeyIsRejected(): Unit {
        let t = NameTable()
        t.add(0u32, 1u32, 'a')
        var rejected = false
        try {
            t.add(0u32, 1u32, 'b') // 重复键
        } catch (ex: JitException) {
            rejected = true
        }
        @Assert(rejected, true)
        var rejected2 = false
        try {
            t.add(0u32, 0u32, 'c') // 回退
        } catch (ex: JitException) {
            rejected2 = true
        }
        @Assert(rejected2, true)
        @Assert(t.size, 1)
    }

    /** 坏载荷：空名字（`strLen = 0`）与越界 `strOff + strLen` ⇒ 拒绝（§11.6 加载器校验）。 */
    @TestCase
    public func emptyOrOutOfRangeNameIsRejected(): Unit {
        // 手工构造：count=1，strLen=0
        let w = ByteWriter()
        w.wU32(1u32)
        w.wU32(0u32)
        w.wU32(0u32)
        w.wU32(0u32)
        w.wU32(0u32)
        var r1 = false
        try {
            NameTable.decode(w.take())
        } catch (ex: JitException) {
            r1 = true
        }
        @Assert(r1, true)

        // strOff + strLen 超出 strBytes
        let w2 = ByteWriter()
        w2.wU32(1u32)
        w2.wU32(0u32)
        w2.wU32(0u32)
        w2.wU32(0u32)
        w2.wU32(4u32) // strLen=4，而 strBytes 只有 2 字节
        w2.wBytes([0x61u8, 0x62u8])
        var r2 = false
        try {
            NameTable.decode(w2.take())
        } catch (ex: JitException) {
            r2 = true
        }
        @Assert(r2, true)

        // 非法 UTF-8
        let w3 = ByteWriter()
        w3.wU32(1u32)
        w3.wU32(0u32)
        w3.wU32(0u32)
        w3.wU32(0u32)
        w3.wU32(1u32)
        w3.wBytes([0xFFu8])
        var r3 = false
        try {
            NameTable.decode(w3.take())
        } catch (ex: JitException) {
            r3 = true
        }
        @Assert(r3, true)
    }

    /** 空名字表（count = 0）合法——名字表稀疏，段恒存在（§11.6「`count` 可为 0」）。 */
    @TestCase
    public func emptyNameTableIsLegal(): Unit {
        let t = NameTable()
        t.freeze()
        let bs = t.encode()
        @Assert(bs.size, 4)
        let back = NameTable.decode(bs)
        @Assert(back.size, 0)
        @Assert(back.lookup(0u32, 0u32).isNone(), true)
    }
}

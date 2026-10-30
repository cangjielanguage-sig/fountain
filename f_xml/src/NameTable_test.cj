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
package fountain::f_xml

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_base.UnsafeBytes

@Test
public class NameTable_test {
    private func scratchOf(text: String): ByteScratch {
        let scratch = ByteScratch()
        for (r in text.runes()) {
            scratch.putCp(r.position())
        }
        scratch
    }

    private func hashOf(text: String): Int64 {
        var hash = NameTable.kFnvOffset
        for (r in text.runes()) {
            hash = NameTable.fold(hash, r.position())
        }
        hash
    }

    private func insertName(table: NameTable, text: String, prefix: ?String, local: String): Unit {
        table.insert(this.hashOf(text), text, prefix, local)
    }

    private func bytesEqual(a: String, b: String): Bool {
        let left = a.unsafeBytes()
        let right = b.unsafeBytes()
        if (left.size != right.size) {
            return false
        }
        for (i in 0..left.size) {
            if (left[i] != right[i]) {
                return false
            }
        }
        true
    }

    /** 同名第二次查询命中，且不再插入、不再分配新 `String`。 */
    @TestCase
    public func hitReusesStoredString(): Unit {
        let table = NameTable()
        let first = table.lookup(this.hashOf("item"), this.scratchOf("item"))
        assertTrue(first.isNone(), "首次查询应为未命中")
        assertTrue(table.misses == 1 && table.hits == 0, "misses=${table.misses} hits=${table.hits}")
        this.insertName(table, "item", None, "item")
        assertTrue(table.insertions == 1 && table.insertions == 1, "insertions=${table.insertions}")
        let second = table.lookup(this.hashOf("item"), this.scratchOf("item"))
        match (second) {
            case Some(entry) => assertTrue(this.bytesEqual(entry.local, "item"), "命中内容应为 item")
            case None => assertTrue(false, "同名第二次查询应命中")
        }
        assertTrue(table.hits == 1 && table.misses == 1, "hits=${table.hits} misses=${table.misses}")
        assertTrue(table.insertions == 1, "重复查询不应再插入")
    }

    /** 不同名各自插入，计数按次递增。 */
    @TestCase
    public func distinctNamesInsertedSeparately(): Unit {
        let table = NameTable()
        this.insertName(table, "a", None, "a")
        this.insertName(table, "b", None, "b")
        this.insertName(table, "c", None, "c")
        assertTrue(table.insertions == 3 && table.insertions == 3, "insertions=${table.insertions}")
        match (table.lookup(this.hashOf("c"), this.scratchOf("c"))) {
            case Some(entry) => assertTrue(this.bytesEqual(entry.local, "c"), "c 应命中原名")
            case None => assertTrue(false, "c 应命中")
        }
    }

    /** 同 hash 不同内容：各自成条，绝不串名（本变更最危险的失效模式）。 */
    @TestCase
    public func sameHashDifferentNamesDoNotCollide(): Unit {
        let table = NameTable()
        const forced: Int64 = 0x5EED
        table.insert(forced, "aa", None, "aa")
        table.insert(forced, "bb", None, "bb")
        assertTrue(table.insertions == 2, "不同名应各自插入，实际 ${table.insertions}")
        match (table.lookup(forced, this.scratchOf("aa"))) {
            case Some(entry) => assertTrue(this.bytesEqual(entry.local, "aa"), "应命中 aa，实际 ${entry.local}")
            case None => assertTrue(false, "aa 应命中")
        }
        match (table.lookup(forced, this.scratchOf("bb"))) {
            case Some(entry) => assertTrue(this.bytesEqual(entry.local, "bb"), "应命中 bb，实际 ${entry.local}")
            case None => assertTrue(false, "bb 应命中")
        }
        // 同 hash、不同长度的第三个名字：必须继续探查并判为未命中，而不是错认成 aa。
        let probe = table.lookup(forced, this.scratchOf("ccc"))
        assertTrue(probe.isNone(), "ccc 不在表里，不得命中")
    }

    /** `p:x` 与 `x` 互不命中，且命中时前缀已切分。 */
    @TestCase
    public func prefixAndLocalArePresplit(): Unit {
        let table = NameTable()
        this.insertName(table, "p:x", Some("p"), "x")
        this.insertName(table, "x", None, "x")
        assertTrue(table.insertions == 2, "带前缀与不带前缀是两个名字")
        match (table.lookup(this.hashOf("p:x"), this.scratchOf("p:x"))) {
            case Some(entry) =>
                let prefix = match (entry.prefix) {
                    case Some(p) => p
                    case None => ""
                }
                assertTrue(prefix == "p" && entry.local == "x", "切分应为 p / x，实际 ${prefix} / ${entry.local}")
            case None => assertTrue(false, "p:x 应命中")
        }
        match (table.lookup(this.hashOf("x"), this.scratchOf("x"))) {
            case Some(entry) => assertTrue(entry.prefix.isNone(), "x 不应有前缀")
            case None => assertTrue(false, "x 应命中")
        }
    }

    /** 非 ASCII、组合字符与带前缀的非 ASCII 名字。 */
    @TestCase
    public func nonAsciiAndCombiningNames(): Unit {
        let table = NameTable()
        this.insertName(table, "名字", None, "名字")
        this.insertName(table, "a\u{0300}", None, "a\u{0300}")
        this.insertName(table, "日本:語", Some("日本"), "語")
        assertTrue(table.insertions == 3, "三个不同的非 ASCII 名字，实际 ${table.insertions}")
        match (table.lookup(this.hashOf("名字"), this.scratchOf("名字"))) {
            case Some(entry) => assertTrue(this.bytesEqual(entry.local, "名字"), "名字 应命中自身")
            case None => assertTrue(false, "名字 应命中")
        }
        match (table.lookup(this.hashOf("a\u{0300}"), this.scratchOf("a\u{0300}"))) {
            case Some(entry) => assertTrue(this.bytesEqual(entry.local, "a\u{0300}"), "组合字符应逐码点一致")
            case None => assertTrue(false, "组合字符名应命中")
        }
        match (table.lookup(this.hashOf("日本:語"), this.scratchOf("日本:語"))) {
            case Some(entry) =>
                let prefix = match (entry.prefix) {
                    case Some(p) => p
                    case None => ""
                }
                assertTrue(this.bytesEqual(prefix, "日本") && this.bytesEqual(entry.local, "語"), "非 ASCII 前缀切分错误")
            case None => assertTrue(false, "日本:語 应命中")
        }
    }

    /** 有界：超过 `maxEntries` 后停止插入，已有条目仍可命中。 */
    @TestCase
    public func boundedByMaxEntries(): Unit {
        let table = NameTable(maxEntries: 4)
        for (i in 0..8) {
            let name = "n${i}"
            this.insertName(table, name, None, name)
        }
        assertTrue(table.insertions == 4, "insertions 应停在上限 4，实际 ${table.insertions}")
        assertTrue(table.insertions == 4, "distinct 应为 4，实际 ${table.insertions}")
        for (i in 0..4) {
            let name = "n${i}"
            match (table.lookup(this.hashOf(name), this.scratchOf(name))) {
            case Some(entry) => assertTrue(this.bytesEqual(entry.local, name), "${name} 应命中")
            case None => assertTrue(false, "${name} 应命中")
            }
        }
        assertTrue(table.lookup(this.hashOf("n7"), this.scratchOf("n7")).isNone(), "超限后不再插入，n7 不应命中")
    }

    /** 扩容重建后仍能命中（负载因子 0.5 触发翻倍）。 */
    @TestCase
    public func rebuildKeepsEntries(): Unit {
        let table = NameTable()
        for (i in 0..200) {
            let name = "k${i}"
            this.insertName(table, name, None, name)
        }
        assertTrue(table.insertions == 200, "应插入 200 条，实际 ${table.insertions}")
        for (i in 0..200) {
            let name = "k${i}"
            match (table.lookup(this.hashOf(name), this.scratchOf(name))) {
            case Some(entry) => assertTrue(this.bytesEqual(entry.local, name), "${name} 重建后应命中")
            case None => assertTrue(false, "${name} 重建后应命中")
            }
        }
    }
}

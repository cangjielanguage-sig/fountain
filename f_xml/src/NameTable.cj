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

import std.collection.ArrayList
import fountain::f_base.UnsafeBytes

/** 驻留表命中结果：**已切分**的前缀与本地名（`prefix` 为空表示无冒号）。 */
internal struct NameEntry {
    let prefix: ?String
    let local: String

    init(prefix: ?String, local: String) {
        this.prefix = prefix
        this.local = local
    }
}

/**
 * 名字驻留表：开放寻址 + 逐字节（等价逐 rune）比对。
 *
 * 判定 = 「hash 相等 **且** 字节序列相等」。只比 hash 会产生静默错误的名字，
 * 是本变更唯一不可接受的失效模式（`design.md` D1），所以比对必须是全量的。
 *
 * 有界：条目数到 `maxEntries` 后**停止插入**，之后只查不插——正确性不变，
 * 只是不再复用；内存不随文档线性增长（D3）。
 *
 * 使用约定：`lookup` 先查（未命中时自增 `misses`），未命中才由调用方 `insert`。
 */
internal class NameTable {
    private static let kInitialCapacity: Int64 = 64
    /** FNV-1a 64 的偏移基（`0xCBF29CE484222325` 的有符号写法）。 */
    static let kFnvOffset: Int64 = -3750763034362895579
    /** FNV-1a 64 的质数（`0x00000100000001B3`）。 */
    static let kFnvPrime: Int64 = 1099511628211

    private let maxEntries: Int64
    /** 槽位 → 条目下标；`-1` 为空。容量恒为 2 的幂。 */
    private var slots: Array<Int64>
    private var mask: Int64
    private var hashes = ArrayList<Int64>()
    private var texts = ArrayList<String>()
    private var locals = ArrayList<String>()
    private var prefixes = ArrayList<Option<String>>()
    /** 名字的 UTF-8 字节，比对用（只在插入时取一次）。 */
    private var encoded = ArrayList<Array<Byte>>()

    var hits: Int64 = 0
    var misses: Int64 = 0
    var insertions: Int64 = 0

    /** 唯一名字数（= 已插入条目数）。 */
    prop distinct: Int64 {
        get() {
            this.texts.size
        }
    }

    init(maxEntries!: Int64 = 65536) {
        this.maxEntries = if (maxEntries < 1) { 1 } else { maxEntries }
        this.slots = Array<Int64>(NameTable.kInitialCapacity, repeat: -1)
        this.mask = NameTable.kInitialCapacity - 1
    }

    /**
     * 查表：命中返回已切分的 `prefix` / `local`。
     *
     * `scratch` 的 `[0..size)` 是本次扫描出的名字字节；与表内字节逐位比较。
     * 表内不同名字数即 `insertions`（插入一次 = 一个唯一名字），不另设计数。
     */
    func lookup(hash: Int64, scratch: ByteScratch): ?NameEntry {
        let len = scratch.size
        let candidate = scratch.bytes()
        var slot = hash & this.mask
        while (true) {
            let entry = this.slots[slot]
            if (entry < 0) {
                break
            }
            if (this.hashes[entry] == hash && NameTable.sameBytes(this.encoded[entry], candidate, len)) {
                this.hits++
                return Some(NameEntry(this.prefixes[entry], this.locals[entry]))
            }
            slot = (slot + 1) & this.mask
        }
        this.misses++
        None
    }

    private static func sameBytes(stored: Array<Byte>, candidate: Array<Byte>, len: Int64): Bool {
        if (stored.size != len) {
            return false
        }
        for (i in 0..len) {
            if (stored[i] != candidate[i]) {
                return false
            }
        }
        true
    }

    /** 插入一条：达到上限后静默不再插入（调用方拿到的仍是正确的名字）。 */
    func insert(hash: Int64, text: String, prefix: ?String, local: String): Unit {
        if (this.texts.size >= this.maxEntries) {
            return
        }
        this.growIfNeeded(this.texts.size + 1)
        let index = this.texts.size
        this.hashes.add(hash)
        this.texts.add(text)
        this.locals.add(local)
        this.prefixes.add(prefix)
        this.encoded.add(text.unsafeBytes())
        var slot = hash & this.mask
        while (this.slots[slot] >= 0) {
            slot = (slot + 1) & this.mask
        }
        this.slots[slot] = index
        this.insertions++
    }

    private func growIfNeeded(next: Int64): Unit {
        // 负载因子 ≤ 0.5；到上限后不再扩容（此时仍保证至少一半空槽，探查必然终止）。
        if (next <= this.maxEntries && next > (this.mask + 1) / 2) {
            this.rebuild((this.mask + 1) * 2)
        }
    }

    private func rebuild(capacity: Int64): Unit {
        this.slots = Array<Int64>(capacity, repeat: -1)
        this.mask = capacity - 1
        var i: Int64 = 0
        while (i < this.hashes.size) {
            var slot = this.hashes[i] & this.mask
            while (this.slots[slot] >= 0) {
                slot = (slot + 1) & this.mask
            }
            this.slots[slot] = i
            i++
        }
    }

    /** FNV-1a：把一个码点并入已有 hash（`h = (h ^ cp) * prime`）。 */
    @OverflowWrapping
    static func fold(hash: Int64, cp: Int64): Int64 {
        (hash ^ cp) * NameTable.kFnvPrime
    }
}

/*
Copyright (c) 2025 WuJingrun（吴京润）

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
package fountain::f_collection

import fountain::f_base.*

class BitSetIterator <: Iterator<Bool> {
    private var current: UInt64 = 0
    BitSetIterator(private let set: BitSet) {}

    public func next(): ?Bool {
        let r = set.get(current)
        current++
        r
    }
}

public class BitSet <: Iterable<Bool> {
    private static let MASK = 1u64 << 63
    private let bits: ArrayList<UInt64>

    public init() {
        this(1)
    }
    public init(capacity: Int64) {
        bits = ArrayList<UInt64>(capacity)
    }
    public init(set: BitSet) {
        this.bits = ArrayList<UInt64>(set.bits)
    }
    public prop size: Int64 {
        get() {
            bits.size * 64
        }
    }
    public func iterator(): Iterator<Bool> {
        BitSetIterator(this)
    }
    private func growIfNeed(index: UInt64, grow!: Bool = true): Int64 {
        let idx = (index / 64u64).toInt()
        if (grow && idx >= bits.size) {
            bits.add(all: Array<UInt64>(idx - bits.size + 1, repeat: 0))
        }
        idx
    }
    private func growIfNeed(index: Int64, grow!: Bool = true): Int64 {
        growIfNeed(index.toUInt(), grow: grow)
    }
    private func computePosition(index: UInt64): UInt64 {
        (MASK >> (index % 64))
    }
    private func computePosition(index: Int64): UInt64 {
        computePosition(index.toUInt())
    }
    func get(index: UInt64): ?Bool {
        let idx = growIfNeed(index, grow: false)
        if (idx >= bits.size) {
            None<Bool>
        } else {
            (bits[idx] & computePosition(index)) != 0
        }
    }
    func get(index: Int64): ?Bool {
        get(index.toUInt())
    }
    public func contains<T>(value: T): Bool where T <: Hashable {
        this[value.hashCode()]
    }
    private func set<T>(value: T, store: Bool): Bool where T <: Hashable {
        let h = value.hashCode().toUInt()
        let idx = growIfNeed(h, grow: store)
        if (idx >= bits.size) {
            return false
        }
        if (let i <- computePosition(h) && (bits[idx] & i) != 0) {
            if (store) {
                bits[idx] |= i
            } else {
                bits[idx] &= !i
            }
            true
        } else {
            false
        }
    }
    public func set<T>(value: T): Bool where T <: Hashable {
        set<T>(value, true)
    }
    public func remove<T>(value: T): Bool where T <: Hashable {
        set<T>(value, false)
    }
    public operator func [](index: UInt32): Bool {
        this[UInt64(index)]
    }
    public operator func [](index: Int32): Bool {
        this[Int64(index)]
    }
    public operator func [](index: UInt64): Bool {
        get(index) ?? false
    }
    public operator func [](index: Int64): Bool {
        this[index.toUInt()]
    }
    public operator func [](index: UInt32, value!: Bool): Unit {
        this[UInt64(index)] = value
    }
    public operator func [](index: Int32, value!: Bool): Unit {
        this[Int64(index)] = value
    }
    public operator func [](index: UInt64, value!: Bool): Unit {
        let idx = growIfNeed(index, grow: value)
        let mask = computePosition(index)
        if (idx >= bits.size) {
            return
        } else if (value) {
            bits[idx] |= mask
        } else {
            bits[idx] &= !mask
        }
    }
    public operator func [](index: Int64, value!: Bool): Unit {
        this[index.toUInt()] = value
    }
    public operator func |(index: UInt32): Bool {
        this | UInt64(index)
    }
    public operator func |(index: Int32): Bool {
        this | Int64(index)
    }
    public operator func |(index: UInt64): Bool {
        let idx = growIfNeed(index, grow: true)
        let val = bits[idx]
        let r = (val | computePosition(index))
        bits[idx] = r
        r == val
    }
    public operator func |(index: Int64): Bool {
        this | index.toUInt()
    }
    public operator func &(index: UInt32): Bool {
        this & UInt64(index)
    }
    public operator func &(index: Int32): Bool {
        this & Int64(index)
    }
    public operator func &(index: UInt64): Bool {
        let idx = growIfNeed(index, grow: true)
        let val = bits[idx]
        let mask = computePosition(index)
        let r = val & mask
        bits[idx] = r
        r != 0
    }
    public operator func &(index: Int64): Bool {
        this & index.toUInt()
    }
    /**
     * 切换指定bit位的值，返回切换之前的状态
     */
    public operator func ^(index: UInt32): Bool {
        this ^ UInt64(index)
    }

    public operator func ^(index: Int32): Bool {
        this ^ Int64(index)
    }
    public operator func ^(index: UInt64): Bool {
        let idx = growIfNeed(index, grow: true)
        let mask = computePosition(index)
        if ((bits[idx] & mask) == 0) {
            bits[idx] |= mask
            false
        } else {
            bits[idx] &= !mask
            true
        }
    }
    public operator func ^(index: Int64): Bool {
        this ^ index.toUInt()
    }
}

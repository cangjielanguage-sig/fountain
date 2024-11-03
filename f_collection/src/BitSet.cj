/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
*/
package f_collection

import f_base.*

class BitSetIterator <: Iterator<Bool> {
    private var current: UInt32 = 0
    BitSetIterator(private let set: BitSet){}

    public func next(): ?Bool{
        let r = set.get(current)
        current++
        r
    }
}
public class BitSet <: Iterable<Bool> {
    private static let MASK = 1u64 << 63
    private let bits = ArrayList<UInt64>()

    public init(){
        this(1)
    }
    public init(capacity: Int64){
        var i = 0
        while(i < capacity) {
            bits.append(0)
            i++
        }
    }
    public init(set: BitSet){
        var idx = 0u32
        for(v in set){
            if(v){
                this[idx]
            }
            idx++
        }
    }
    public prop size: Int64 {
        get() {
            bits.size * 64
        }
    }
    public func iterator(): Iterator<Bool> {
        BitSetIterator(this)
    }
    private func growIfNeed(index: UInt32, grow!: Bool = true): Int64 {
        let idx = Int64(index / 64)
        if (grow && idx >= bits.size) {
            bits.appendAll(Array<UInt64>(idx - bits.size + 1, repeat: 0u64))
        }
        idx
    }
    func get(index: UInt32): ?Bool {
        let idx = growIfNeed(index, grow: false)
        if (idx >= bits.size) {
            None
        } else {
            (bits[idx] & (MASK >> UInt64(index % 64))) != 0
        }
    }
    public operator func [](index: UInt32): Bool {
        get(index) ?? false
    }
    public operator func [](index: Int32): Bool {
        this[index.toUInt()]
    }
    private func uint64ToUInt32(index: UInt64){
        UInt32(index & 0xffff_ffff)
    }
    public operator func [](index: UInt64): Bool {
        this[uint64ToUInt32(index)]
    }
    public operator func [](index: Int64): Bool {
        this[index.toUInt()]
    }
    public operator func [](index: UInt32, value!: Bool): Unit {
        let idx = growIfNeed(index)
        if (value) {
            bits[idx] |= MASK >> UInt64(index % 64)
        } else {
            bits[idx] &= !(MASK >> UInt64(index % 64))
        }
    }
    public operator func [](index: Int32, value!: Bool): Unit {
        this[index.toUInt()] = value
    }
    public operator func [](index: UInt64, value!: Bool): Unit {
        this[uint64ToUInt32(index)] = value
    }
    public operator func [](index: Int64, value!: Bool): Unit {
        this[index.toUInt()] = value
    }
    public operator func |(index: UInt32): Bool {
        let idx = growIfNeed(index)
        let val = bits[idx]
        let r = (val | (MASK >> UInt64(index % 64)))
        bits[idx] = val
        r == val
    }
    public operator func |(index: Int32): Bool {
        this | index.toUInt()
    }
    public operator func |(index: UInt64): Bool {
        this | uint64ToUInt32(index)
    }
    public operator func |(index: Int64): Bool {
        this | index.toUInt()
    }
    public operator func &(index: UInt32): Bool {
        let idx = growIfNeed(index)
        let val = bits[idx]
        let r = (val & (MASK >> UInt64(index % 64)))
        bits[idx] = val & (val | (MASK >> UInt64(index % 64)))
        r != 0
    }
    public operator func &(index: Int32): Bool {
        this & index.toUInt()
    }
    public operator func &(index: UInt64): Bool {
        this & uint64ToUInt32(index)
    }
    public operator func &(index: Int64): Bool {
        this & index.toUInt()
    }
    /**
     * 切换指定bit位的值，返回切换之前的状态
     */
    public operator func ^(index: UInt32): Bool {
        let idx = growIfNeed(index)
        let mask = MASK >> UInt64(index % 64)
        if ((bits[idx] & mask) == 0) {
            bits[idx] |= mask
            false
        } else {
            bits[idx] &= !mask
            true
        }
    }

    public operator func ^(index: Int32): Bool {
        this ^ index.toUInt()
    }
    public operator func ^(index: UInt64): Bool {
        this ^ uint64ToUInt32(index)
    }
    public operator func ^(index: Int64): Bool {
        this ^ index.toUInt()
    }
}

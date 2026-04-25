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
package fountain::f_store

import fountain::f_base.HashBuilder

/** 字节数组包装类型，用作 ConcurrentSkipListMap 的 key。
 *  值类型 struct，按内容比较和哈希。
 *  实现 Comparable（含 Equatable）+ Hashable。
 */
public struct ByteArray <: Comparable<ByteArray> & Hashable {
    public let bytes: Array<Byte>

    public init(bytes: Array<Byte>) {
        this.bytes = bytes
    }

    /** 字典序比较：逐字节比较，短前缀为小，全等则相等 */
    public func compare(other: ByteArray): Ordering {
        let a = this.bytes
        let b = other.bytes
        let minLen = if (a.size < b.size) { a.size } else { b.size }
        for (i in 0..minLen) {
            match (a[i].compare(b[i])) {
                case EQ => continue
                case x => return x
            }
        }
        if (a.size < b.size) {
            return LT
        }
        if (a.size > b.size) {
            return GT
        }
        return EQ
    }

    public func hashCode(): Int64 {
        HashBuilder().append<Byte, Array<Byte>>(bytes).build()
    }
}

/** LSM-Tree 条目值。不可变对象。 */
public class EntryValue {
    /** 值，None 表示 tombstone（删除标记） */
    public let value: ?Array<Byte>
    /** 全局单调递增序列号 */
    public let sequence: Int64
    /** 过期时间戳（纳秒），None = 永不过期 */
    public let expireAt: ?Int64

    public init(value: ?Array<Byte>, sequence: Int64, expireAt!: ?Int64 = None) {
        this.value = value
        this.sequence = sequence
        this.expireAt = expireAt
    }
}

/** Store 关闭后操作抛出此异常 */
public class StoreClosedException <: Exception {
    public init() {
        super("Store is closed")
    }
}

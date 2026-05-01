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

/** 字节数组包装类型，用作 ConcurrentSkipListMap 的 key。
 *  值类型 struct，按内容比较和哈希。
 *  实现 Comparable（含 Equatable）+ Hashable。
 */
public struct ByteArray <: Comparable<ByteArray> & Hashable {
    public let bytes: Array<Byte>

    public init(bytes: Array<Byte>) {
        this.bytes = bytes
    }

    /** 字典序比较：逐字节比较，短前缀为小，全等则相等。
     *  优化：8 字节批量比较减少循环次数；直接整数比较避免 Ordering 开销。
     */
    public func compare(other: ByteArray): Ordering {
        let a = this.bytes
        let b = other.bytes
        let minLen = if (a.size <= b.size) { a.size } else { b.size }
        var i: Int64 = 0
        // 8 字节批量比较
        while (i + 8 <= minLen) {
            for (j in 0..8) {
                if (a[i] != b[i]) {
                    return if (a[i] < b[i]) { Ordering.LT } else { Ordering.GT }
                }
                i++
            }
        }
        // 剩余字节逐字节比较
        while (i < minLen) {
            if (a[i] != b[i]) {
                return if (a[i] < b[i]) { Ordering.LT } else { Ordering.GT }
            }
            i++
        }
        a.size.compare(b.size)
    }

    public func hashCode(): Int64 {
        HashBuilder().append<Byte, Array<Byte>>(bytes).build()
    }
}

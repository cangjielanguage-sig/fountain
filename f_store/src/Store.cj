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
import std.io.IOStream
import std.fs.{File, OpenMode, Path}
import std.sync.AtomicBool

@When[os == "Linux"]
import fountain::f_io.IOUringStream

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
        let minLen = if (a.size <= b.size) { a.size } else { b.size }
        for (i in 0..minLen) {
            match (a[i].compare(b[i])) {
                case EQ => continue
                case x => return x
            }
        }
        a.size.compare(b.size)
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

/** 创建存储 IO 流的工厂函数。
 *  Linux: 使用 IOUringStream（双 ring 异步 IO）
 *  非 Linux: 使用 std.fs.File（同步 IO）
 *  统一返回 IOStream 接口。
 *  ★ 调用方必须保持 File 对象存活，否则 fd 失效（Linux 下 IOUringStream 只持有 fd 不持有 File）
 */
@When[os == "Linux"]
public func createStoreStream(path: String, mode: OpenMode, entries!: UInt32 = 64): IOStream {
    let file = File(path, mode)
    IOUringStream(Int32(file.fileDescriptor.fileHandle), entries)
}

@When[os != "Linux"]
public func createStoreStream(path: String, mode: OpenMode, entries!: UInt32 = 64): IOStream {
    File(path, mode)
}

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

// === 小端序读写工具（WAL 专用） ===

func writeUInt32LE(buf: Array<Byte>, offset: Int64, value: UInt32): Int64 {
    buf[offset] = UInt8(value & 0xFFu32)
    buf[offset + 1] = UInt8((value >> 8) & 0xFFu32)
    buf[offset + 2] = UInt8((value >> 16) & 0xFFu32)
    buf[offset + 3] = UInt8((value >> 24) & 0xFFu32)
    offset + 4
}

@OverflowWrapping
func writeInt64LE(buf: Array<Byte>, offset: Int64, value: Int64): Int64 {
    let uv = value.toUInt()
    buf[offset] = UInt8(uv & 0xFFu64)
    buf[offset + 1] = UInt8((uv >> 8) & 0xFFu64)
    buf[offset + 2] = UInt8((uv >> 16) & 0xFFu64)
    buf[offset + 3] = UInt8((uv >> 24) & 0xFFu64)
    buf[offset + 4] = UInt8((uv >> 32) & 0xFFu64)
    buf[offset + 5] = UInt8((uv >> 40) & 0xFFu64)
    buf[offset + 6] = UInt8((uv >> 48) & 0xFFu64)
    buf[offset + 7] = UInt8((uv >> 56) & 0xFFu64)
    offset + 8
}

func readUInt32LE(buf: Array<Byte>, offset: Int64): UInt32 {
    UInt32(buf[offset]) |
    (UInt32(buf[offset + 1]) << 8) |
    (UInt32(buf[offset + 2]) << 16) |
    (UInt32(buf[offset + 3]) << 24)
}

@OverflowWrapping
func readInt64LE(buf: Array<Byte>, offset: Int64): Int64 {
    let v = (UInt64(buf[offset])) |
    (UInt64(buf[offset + 1]) << 8) |
    (UInt64(buf[offset + 2]) << 16) |
    (UInt64(buf[offset + 3]) << 24) |
    (UInt64(buf[offset + 4]) << 32) |
    (UInt64(buf[offset + 5]) << 40) |
    (UInt64(buf[offset + 6]) << 48) |
    (UInt64(buf[offset + 7]) << 56)
    v.toInt()
}

// === 小端序读写工具（SSTable 专用） ===

@OverflowWrapping
func writeUInt64LE(buf: Array<Byte>, offset: Int64, value: UInt64): Int64 {
    buf[offset] = UInt8(value & 0xFFu64)
    buf[offset + 1] = UInt8((value >> 8) & 0xFFu64)
    buf[offset + 2] = UInt8((value >> 16) & 0xFFu64)
    buf[offset + 3] = UInt8((value >> 24) & 0xFFu64)
    buf[offset + 4] = UInt8((value >> 32) & 0xFFu64)
    buf[offset + 5] = UInt8((value >> 40) & 0xFFu64)
    buf[offset + 6] = UInt8((value >> 48) & 0xFFu64)
    buf[offset + 7] = UInt8((value >> 56) & 0xFFu64)
    offset + 8
}

func readUInt64LE(buf: Array<Byte>, offset: Int64): UInt64 {
    UInt64(buf[offset]) |
    (UInt64(buf[offset + 1]) << 8) |
    (UInt64(buf[offset + 2]) << 16) |
    (UInt64(buf[offset + 3]) << 24) |
    (UInt64(buf[offset + 4]) << 32) |
    (UInt64(buf[offset + 5]) << 40) |
    (UInt64(buf[offset + 6]) << 48) |
    (UInt64(buf[offset + 7]) << 56)
}

// === MemTable 刷盘 ===

/** 全局 SSTable 序列号，每次 flush 自增，确保文件名唯一 */
let sstableFileSeq = AtomicInt64(0)

/** 将 immutable MemTable 刷盘为 SSTable 文件。
 *  遍历 MemTable 的有序迭代器，逐条写入 SSTable。
 *  超过 64MB 时自动创建新 SSTable。
 *  返回所有生成的 SSTable 列表（已 finishWrite，处于 Readable 状态）。
 */
func flushMemTable(memTable: MemTable, sstDir: String, level: Int64): ArrayList<SSTable> {
    let result = ArrayList<SSTable>()
    if (!exists(sstDir)) {
        Directory.create(sstDir, recursive: true)
    }
    var sstIndex: Int64 = sstableFileSeq.incrFetch()
    var writer = SSTable("${sstDir}/L${level}_${sstIndex}.sst", 64)
    let iter = memTable.iterator()
    while (let Some((key, entry)) <- iter.next()) {
        writer.write(key, entry)
        if (writer.isFull()) {
            writer.finishWrite()
            result.add(writer)
            sstIndex++
            writer = SSTable("${sstDir}/L${level}_${sstIndex}.sst", 64)
        }
    }
    // 最后一个 writer（可能写了数据也可能为空）
    if (writer.getEntryCount() > 0) {
        writer.finishWrite()
        result.add(writer)
    } else {
        writer.close()
    }
    result
}

// === WAL 清理 ===

/** 清理指定 WAL 目录下所有已恢复的旧 .wal 文件。
 *  在 Store.init 中创建新 WAL 前调用，此时旧 WAL 的数据已恢复到 MemTable。
 */
func cleanupOldWALFiles(walDir: String): Unit {
    if (!exists(walDir)) {
        return
    }
    Directory.walk(walDir) { fi: FileInfo =>
        if (fi.path.extensionName == "wal" && !fi.isDirectory()) {
            try {
                remove(fi.path.toString())
            } catch (_: Exception) {}
        }
        true
    }
}
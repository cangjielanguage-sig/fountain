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
    UInt32(buf[offset]) | (UInt32(buf[offset + 1]) << 8) | (UInt32(buf[offset + 2]) << 16) | (UInt32(buf[offset + 3]) <<
        24)
}

@OverflowWrapping
func readInt64LE(buf: Array<Byte>, offset: Int64): Int64 {
    let v = (UInt64(buf[offset])) | (UInt64(buf[offset + 1]) << 8) | (UInt64(buf[offset + 2]) << 16) | (UInt64(buf[offset +
            3]) << 24) | (UInt64(buf[offset + 4]) << 32) | (UInt64(buf[offset + 5]) << 40) | (UInt64(buf[offset + 6]) <<
        48) | (UInt64(buf[offset + 7]) << 56)
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
    UInt64(buf[offset]) | (UInt64(buf[offset + 1]) << 8) | (UInt64(buf[offset + 2]) << 16) | (UInt64(buf[offset + 3]) <<
        24) | (UInt64(buf[offset + 4]) << 32) | (UInt64(buf[offset + 5]) << 40) | (UInt64(buf[offset + 6]) << 48) | (UInt64(buf[offset +
            7]) << 56)
}

// === 定位读取 ===
// pread 避免 seek+read 的并发竞争，单 syscall 完成定位与读取

@When[os == "Linux"]
foreign func pread(fd: Int32, buf: CPointer<Byte>, count: Int64, offset: Int64): Int64

@When[os == "Linux"]
func positionedRead(fd: Int32, buf: CPointer<Byte>, bufSize: Int64, offset: Int64): Bool {
    let n = unsafe { pread(fd, buf, bufSize, offset) }
    n == bufSize
}

@When[os != "Linux"]
func positionedRead(file: File, buf: Array<Byte>, offset: Int64): Bool {
    file.seek(SeekPosition.Begin(offset))
    file.read(buf)
    true
}

// === MemTable 刷盘 ===

/** 从迭代器写入 SSTable 过程中发生的异常 */
public class SSTableWritingException <: BaseException {
    init(caused: Exception) {
        super(caused)
    }
}

/** 全局 SSTable 序列号，每次 flush 自增，确保文件名唯一 */
let sstableFileSeq = AtomicInt64(0)

/** 将有序迭代器的数据逐条写入 SSTable，满 64MB 自动创建新 SSTable。
 *  返回所有已 finishWrite 的 SSTable 列表（Readable 状态）。
 *  异常时自动关闭当前 writer 并删除孤儿文件。
 */
func writeStreamToSSTables(iter: Iterator<(ByteArray, EntryValue)>, sstDir: String, level: Int64): ArrayList<SSTable> {
    let result = ArrayList<SSTable>()
    if (!exists(sstDir)) {
        Directory.create(sstDir, recursive: true)
    }
    var sstIndex: Int64 = sstableFileSeq.incrFetch()
    var writerPath = "${sstDir}/L${level}_${sstIndex}.sst"
    var writer = SSTable(writerPath, 64)
    try {
        while (let Some((key, entry)) <- iter.next()) {
            writer.write(key, entry)
            if (writer.isFull()) {
                writer.finishWrite(level: level)
                result.add(writer)
                sstIndex++
                writerPath = "${sstDir}/L${level}_${sstIndex}.sst"
                writer = SSTable(writerPath, 64)
            }
        }
        if (writer.getEntryCount() > 0) {
            writer.finishWrite(level: level)
            result.add(writer)
        } else {
            writer.close()
        }
    } catch (e: Exception) {
        writer.close()
        // 删除可能部分写入的孤儿文件
        try {
            if (exists(writerPath)) {
                remove(writerPath)
            }
        } catch (e2: Exception) {
            let thrown = SSTableWritingException(e2)
            thrown.addSuppressed(e)
            throw thrown
        }
        throw e
    }
    result
}

/** 将 immutable MemTable 刷盘为 SSTable 文件。
 *  遍历 MemTable 的有序迭代器，逐条写入 SSTable。
 *  超过 64MB 时自动创建新 SSTable。
 *  返回所有生成的 SSTable 列表（已 finishWrite，处于 Readable 状态）。
 */
func flushMemTable(memTable: MemTable, sstDir: String, level: Int64): ArrayList<SSTable> {
    writeStreamToSSTables(memTable.iterator(), sstDir, level)
}

// === SSTable 文件名解析 ===
// 文件名格式: L{level}_{sstIndex}.sst

/** 从 SSTable 文件路径解析 level。文件名格式: L{level}_{sstIndex}.sst */
func parseLevelFromSSTablePath(path: String): Int64 {
    let parts = path.split("/")
    let fileName = parts[parts.size - 1]
    let name = if (fileName.endsWith(".sst")) {
        fileName[0 .. (fileName.size - 4)]
    } else {
        fileName
    }
    if (name.startsWith("L")) {
        let rest = name[1 .. name.size]
        let nameParts = rest.split("_")
        if (nameParts.size >= 2) {
            try {
                return Int64.parse(nameParts[0])
            } catch (_: Exception) { return 0 }
        }
    }
    0
}

/** 从 SSTable 文件路径解析 sstIndex。用于重启后恢复 sstableFileSeq。 */
func parseSSTIndexFromPath(path: String): Int64 {
    let parts = path.split("/")
    let fileName = parts[parts.size - 1]
    let name = if (fileName.endsWith(".sst")) {
        fileName[0 .. (fileName.size - 4)]
    } else {
        fileName
    }
    if (name.startsWith("L")) {
        let rest = name[1 .. name.size]
        let nameParts = rest.split("_")
        if (nameParts.size >= 2) {
            try {
                return Int64.parse(nameParts[1])
            } catch (_: Exception) { return 0 }
        }
    }
    0
}

// === WAL 清理 ===

/** 清理指定 WAL 目录下所有已恢复的旧 .wal 文件。
 *  在 Store.init 中创建新 WAL 前调用，此时旧 WAL 的数据已恢复到 MemTable。
 */
func cleanupOldWALFiles(walDir: String): Unit {
    if (!exists(walDir)) {
        return
    }
    Directory.walk(walDir) {
        fi: FileInfo =>
            if (fi.path.extensionName == "wal" && !fi.isDirectory()) {
                try {
                    remove(fi.path.toString())
                } catch (_: Exception) {}
            }
            true
    }
}

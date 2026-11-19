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
package fountain::f_excel

import std.collection.ArrayList
import std.env
import std.fs.{File, OpenMode, Path, removeIfExists}
import std.io.SeekPosition
import fountain::f_base.StringGenerator

/**
 * sharedStrings 的磁盘索引（M3-a）。
 *
 * 解压后的 `sharedStrings.xml` 落到临时文件，内存只保留每个 `<si>` 的 `(offset, length)`；
 * 读取某条时定位并只解那一小段。代价是每次未命中都要 seek + 解析，适合"只读少量行"的场景。
 */
internal class SharedStringIndex <: SharedStringsLookup {
    private let path: Path
    private let offsets: ArrayList<Int64>
    private let lengths: ArrayList<Int64>
    private var file: ?File = None
    private var cacheIndex: Int64 = -1
    private var cacheTable: ?SharedStringTable = None

    private init(path: Path, offsets: ArrayList<Int64>, lengths: ArrayList<Int64>) {
        this.path = path
        this.offsets = offsets
        this.lengths = lengths
    }

    /** 建索引；临时文件创建失败时抛异常，由调用方回退到全量表。 */
    static func build(bytes: Array<Byte>, dir!: ?Path = None): SharedStringIndex {
        let offsets = ArrayList<Int64>()
        let lengths = ArrayList<Int64>()
        scan(bytes, offsets, lengths)
        let baseDir = match (dir) {
            case Some(value) => value
            case None => Path(env.getTempDirectory().toString())
        }
        let file = try {
            File.createTemp(baseDir)
        } catch (e: Exception) {
            throw ExcelException("无法创建 sharedStrings 索引临时文件", e)
        }
        let path = file.info.path
        try {
            file.write(bytes)
            file.flush()
            file.close()
        } catch (e: Exception) {
            try {
                file.close()
            } catch (_: Exception) {}
            try {
                removeIfExists(path)
            } catch (_: Exception) {}
            throw ExcelException("sharedStrings 索引写入失败：${path}", e)
        }
        SharedStringIndex(path, offsets, lengths)
    }

    private static func scan(bytes: Array<Byte>, offsets: ArrayList<Int64>, lengths: ArrayList<Int64>): Unit {
        let n = bytes.size
        var i: Int64 = 0
        while (i + 3 < n) {
            if (bytes[i] == 60u8 && bytes[i + 1] == 115u8 && bytes[i + 2] == 105u8 &&
                (bytes[i + 3] == 62u8 || bytes[i + 3] == 32u8 || bytes[i + 3] == 47u8)) {
                let start = i
                let end = findClose(bytes, i)
                if (end > start) {
                    offsets.add(start)
                    lengths.add(end - start)
                    i = end
                    continue
                }
            }
            i++
        }
    }

    private static func findClose(bytes: Array<Byte>, start: Int64): Int64 {
        let n = bytes.size
        var i = start + 3
        while (i + 4 < n) {
            if (bytes[i] == 60u8 && bytes[i + 1] == 47u8 && bytes[i + 2] == 115u8 &&
                bytes[i + 3] == 105u8 && bytes[i + 4] == 62u8) {
                return i + 5
            }
            i++
        }
        -1
    }

    public func size(): Int64 {
        Int64(this.offsets.size)
    }

    private func ensureFile(): File {
        match (this.file) {
            case Some(handle) => handle
            case None =>
                let handle = try {
                    File(this.path, OpenMode.Read)
                } catch (e: Exception) {
                    throw ExcelException("无法打开 sharedStrings 索引：${this.path}", e)
                }
                this.file = Some(handle)
                handle
        }
    }

    private func sliceAt(index: Int64): ?String {
        if (index < 0 || index >= Int64(this.offsets.size)) {
            return None<String>
        }
        let handle = this.ensureFile()
        handle.seek(SeekPosition.Begin(this.offsets[index]))
        var remaining = this.lengths[index]
        let collected = ArrayList<UInt8>()
        let buffer = Array<UInt8>(4096, repeat: 0)
        while (remaining > 0) {
            let n = handle.read(buffer)
            if (n <= 0) {
                break
            }
            let take = if (n < remaining) { n } else { remaining }
            var k: Int64 = 0
            while (k < take) {
                collected.add(buffer[k])
                k++
            }
            remaining -= take
        }
        if (collected.size == 0) {
            return None<String>
        }
        Some(String.fromUtf8(collected.toArray()))
    }

    private func parseItem(index: Int64): ?SharedStringTable {
        let piece = match (this.sliceAt(index)) {
            case Some(value) => value
            case None => return None<SharedStringTable>
        }
        let wrapped = StringGenerator()
        wrapped.append<String>("<?xml version=\"1.0\" encoding=\"UTF-8\"?><sst>")
        wrapped.append<String>(piece)
        wrapped.append<String>("</sst>")
        try {
            Some(SharedStringTable.load(wrapped.toString().toArray()))
        } catch (_: Exception) {
            None<SharedStringTable>
        }
    }

    private func tableAt(index: Int64): ?SharedStringTable {
        if (index == this.cacheIndex) {
            match (this.cacheTable) {
                case Some(value) => return Some(value)
                case None => ()
            }
        }
        match (this.parseItem(index)) {
            case Some(table) =>
                this.cacheIndex = index
                this.cacheTable = Some(table)
                Some(table)
            case None => None<SharedStringTable>
        }
    }

    public func get(index: Int64): ?String {
        match (this.tableAt(index)) {
            case Some(table) => table.get(0)
            case None => None<String>
        }
    }

    public func runsAt(index: Int64): ArrayList<TextRun> {
        match (this.tableAt(index)) {
            case Some(table) => table.runsAt(0)
            case None => ArrayList<TextRun>()
        }
    }

    /** 删除临时文件；幂等。 */
    func close(): Unit {
        match (this.file) {
            case Some(handle) =>
                try {
                    handle.close()
                } catch (_: Exception) {}
                this.file = None
            case None => ()
        }
        try {
            removeIfExists(this.path)
        } catch (_: Exception) {}
    }
}

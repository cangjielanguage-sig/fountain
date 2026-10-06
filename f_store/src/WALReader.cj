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

/** WAL 读取器，使用 std.fs.File 同步读取（恢复是启动时一次性操作） */
class WALReader {
    /** 读取 WAL 文件所有完整记录，截断的记录被忽略。
     *  流式逐条读取，避免一次性加载整个文件到内存。 */
    static func readAll(path: String): ArrayList<WALRecord> {
        let result = ArrayList<WALRecord>()
        if (!exists(path)) {
            return result
        }
        let file = File(path, OpenMode.Read)
        let fileSize = file.info.size
        if (fileSize < 36) {
            file.close()
            return result
        }
        try {
            // 流式读取：逐条读 header + data，边读边解析
            let header = Array<Byte>(36, repeat: 0u8)
            while (true) {
                let headerRead = file.read(header)
                if (headerRead < 36) {
                    break // 文件结尾或截断
                }
                let checksum = readUInt32LE(header, 0)
                let sequence = readInt64LE(header, 4)
                let keyLen = readInt64LE(header, 12)
                let valueLen = readInt64LE(header, 20)
                let expireAtVal = readInt64LE(header, 28)
                if (keyLen < 0 || keyLen > 1024 * 1024) {
                    break // 非法数据
                }
                let actualValueLen = if (valueLen >= 0) { valueLen } else { 0 }
                let totalDataLen = keyLen + actualValueLen
                // 读 key + value
                let data = Array<Byte>(totalDataLen, repeat: 0u8)
                if (totalDataLen > 0) {
                    let dataRead = file.read(data)
                    if (dataRead < totalDataLen) {
                        break // 截断的记录
                    }
                }
                let keyBytes = Array<Byte>(keyLen, repeat: 0u8)
                data[0 .. keyLen].copyTo(keyBytes)
                let value: ?Array<Byte> = if (valueLen >= 0) {
                    let valueBytes = Array<Byte>(valueLen, repeat: 0u8)
                    data[keyLen .. keyLen + valueLen].copyTo(valueBytes)
                    Some(valueBytes)
                } else {
                    None
                }
                let expireAt: ?Int64 = if (expireAtVal != 0) { Some(expireAtVal) } else { None }
                // 验证 checksum
                let expected = WALRecordCodec.computeChecksum(sequence, keyBytes, value, expireAt)
                if (checksum != expected) {
                    break // checksum 不匹配，视为截断
                }
                result.add(WALRecord(checksum, sequence, keyBytes, value, expireAt: expireAt))
            }
        } finally {
            file.close()
        }
        result
    }

    /** 从 WAL 文件恢复到 MemTable */
    static func recover(path: String): MemTable {
        let records = readAll(path)
        let mt = MemTable()
        for (record in records) {
            mt.add(ByteArray(record.key), EntryValue(record.value, record.sequence, expireAt: record.expireAt))
        }
        mt
    }

    /** 从目录下所有 WAL 文件恢复（按文件名排序） */
    static func recoverAll(walDir: String): MemTable {
        let mt = MemTable()
        if (!exists(walDir)) {
            return mt
        }
        // 扫描目录，收集 .wal 文件
        let walFiles = ArrayList<String>()
        Directory.walk(walDir) { fi: FileInfo =>
            if (fi.path.extensionName == "wal" && !fi.isDirectory()) {
                walFiles.add(fi.path.toString())
            }
            true
        }
        // 按文件名排序（文件名包含 sequence_start，自然有序）
        sort(walFiles)
        for (walPath in walFiles) {
            let records = readAll(walPath)
            for (record in records) {
                mt.add(ByteArray(record.key), EntryValue(record.value, record.sequence, expireAt: record.expireAt))
            }
        }
        mt
    }
}

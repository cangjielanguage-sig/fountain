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

/** WAL 记录。不可变。
 *  编码格式（小端序）:
 *  checksum(4) + sequence(8) + key_len(8) + value_len(8) + expire_at(8) + key_bytes(key_len) + value_bytes(value_len)
 *  value_len = -1 表示 tombstone（value = None），value_len >= 0 表示正常 value（包括空数组）
 *  expire_at = 0 表示永不过期
 *  checksum 覆盖 sequence + key_len + value_len + expire_at + key_bytes + value_bytes
 */
class WALRecord {
    let checksum: UInt32
    let sequence: Int64
    let key: Array<Byte>
    let value: ?Array<Byte>
    let expireAt: ?Int64

    init(sequence: Int64, key: Array<Byte>, value: ?Array<Byte>, expireAt!: ?Int64 = None) {
        this.sequence = sequence
        this.key = key
        this.value = value
        this.expireAt = expireAt
        this.checksum = WALRecordCodec.computeChecksum(sequence, key, value, expireAt)
    }

    init(checksum: UInt32, sequence: Int64, key: Array<Byte>, value: ?Array<Byte>, expireAt!: ?Int64 = None) {
        this.checksum = checksum
        this.sequence = sequence
        this.key = key
        this.value = value
        this.expireAt = expireAt
    }

    /** 编码为字节数组 */
    func encode(): Array<Byte> {
        let keyLen = key.size
        let valueLen = if (let Some(v) <- value) { v.size } else { -1 }
        let expireAtVal = if (let Some(ea) <- expireAt) { ea } else { 0 }
        // checksum(4) + sequence(8) + key_len(8) + value_len(8) + expire_at(8) + key + value
        let totalLen = 36 + keyLen + (if (valueLen > 0) { valueLen } else { 0 })
        let buf = Array<Byte>(totalLen, repeat: 0u8)
        var offset = 0
        // checksum
        offset = writeUInt32LE(buf, offset, checksum)
        // sequence
        offset = writeInt64LE(buf, offset, sequence)
        // key_len
        offset = writeInt64LE(buf, offset, Int64(keyLen))
        // value_len (-1 = tombstone)
        offset = writeInt64LE(buf, offset, Int64(valueLen))
        // expire_at (0 = never)
        offset = writeInt64LE(buf, offset, expireAtVal)
        // key_bytes
        key.copyTo(buf[offset .. offset + keyLen])
        offset += keyLen
        // value_bytes
        if (let Some(v) <- value) {
            v.copyTo(buf[offset .. offset + valueLen])
            offset += valueLen
        }
        buf
    }

    /** 解码字节数组为 WALRecord，checksum 不匹配返回 None */
    static func decode(bytes: Array<Byte>): ?WALRecord {
        if (bytes.size < 36) {
            return None
        }
        var offset = 0
        let checksum = readUInt32LE(bytes, offset)
        offset += 4
        let sequence = readInt64LE(bytes, offset)
        offset += 8
        let keyLen = readInt64LE(bytes, offset)
        offset += 8
        let valueLen = readInt64LE(bytes, offset)
        offset += 8
        let expireAtVal = readInt64LE(bytes, offset)
        offset += 8
        // 校验 keyLen/valueLen 合法性
        if (keyLen < 0 || valueLen < -1) {
            return None
        }
        // 检查剩余长度
        if (bytes.size < 36 + keyLen + valueLen) {
            return None
        }
        let keyBytes = Array<Byte>(Int64(keyLen), repeat: 0u8)
        bytes[offset .. offset + Int64(keyLen)].copyTo(keyBytes)
        offset += Int64(keyLen)
        let value: ?Array<Byte> = if (valueLen >= 0) {
            let valueBytes = Array<Byte>(Int64(valueLen), repeat: 0u8)
            bytes[offset .. offset + Int64(valueLen)].copyTo(valueBytes)
            offset += Int64(valueLen)
            Some(valueBytes)
        } else {
            None
        }
        let expireAt: ?Int64 = if (expireAtVal != 0) { Some(expireAtVal) } else { None }
        // 验证 checksum
        let expected = WALRecordCodec.computeChecksum(sequence, keyBytes, value, expireAt)
        if (checksum != expected) {
            return None
        }
        WALRecord(checksum, sequence, keyBytes, value, expireAt: expireAt)
    }
}

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

import fountain::f_util.crc32
import fountain::f_base.*

/** WAL 记录。不可变。
 *  编码格式（小端序）:
 *  checksum(4) + sequence(8) + key_len(8) + value_len(8) + expire_at(8) + key_bytes(key_len) + value_bytes(value_len)
 *  value_len = -1 表示 tombstone（value = None），value_len >= 0 表示正常 value（包括空数组）
 *  expire_at = 0 表示永不过期
 *  checksum 覆盖 sequence + key_len + value_len + expire_at + key_bytes + value_bytes
 */
struct WALRecord {
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

    private init(checksum: UInt32, sequence: Int64, key: Array<Byte>, value: ?Array<Byte>, expireAt: ?Int64) {
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
        for (i in 0..keyLen) {
            buf[offset] = key[i]
            offset++
        }
        // value_bytes
        if (let Some(v) <- value) {
            for (i in 0..valueLen) {
                buf[offset] = v[i]
                offset++
            }
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
        // 检查剩余长度
        if (bytes.size < 36 + keyLen + valueLen) {
            return None
        }
        let keyBytes = Array<Byte>(Int64(keyLen), repeat: 0u8)
        for (i in 0..Int64(keyLen)) {
            keyBytes[i] = bytes[offset]
            offset++
        }
        let value: ?Array<Byte> = if (valueLen >= 0) {
            let valueBytes = Array<Byte>(Int64(valueLen), repeat: 0u8)
            for (i in 0..Int64(valueLen)) {
                valueBytes[i] = bytes[offset]
                offset++
            }
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
        WALRecord(checksum, sequence, keyBytes, value, expireAt)
    }
}

/** WAL 记录编解码工具 */
class WALRecordCodec {
    /** 计算 CRC32 校验和，覆盖 sequence + key_len + value_len + expire_at + key_bytes + value_bytes */
    static func computeChecksum(sequence: Int64, key: Array<Byte>, value: ?Array<Byte>, expireAt: ?Int64): UInt32 {
        let keyLen = key.size
        let valueLen = if (let Some(v) <- value) { v.size } else { -1 }
        let expireAtVal = if (let Some(ea) <- expireAt) { ea } else { 0 }
        // 组装待校验数据：sequence(8) + key_len(8) + value_len(8) + expire_at(8) + key + value
        let dataLen = 32 + keyLen + (if (valueLen > 0) { valueLen } else { 0 })
        let data = Array<Byte>(dataLen, repeat: 0u8)
        var offset = 0
        offset = writeInt64LE(data, offset, sequence)
        offset = writeInt64LE(data, offset, Int64(keyLen))
        offset = writeInt64LE(data, offset, Int64(valueLen))
        offset = writeInt64LE(data, offset, expireAtVal)
        for (i in 0..keyLen) {
            data[offset] = key[i]
            offset++
        }
        if (let Some(v) <- value) {
            for (i in 0..valueLen) {
                data[offset] = v[i]
                offset++
            }
        }
        crc32(data)
    }
}

// === 小端序读写工具函数 ===

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

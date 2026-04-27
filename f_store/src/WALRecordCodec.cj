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

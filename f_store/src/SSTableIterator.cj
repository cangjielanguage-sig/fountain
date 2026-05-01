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

/** SSTable 全量/前缀遍历器 */
class SSTableIterator <: Iterator<(ByteArray, EntryValue)> {
    private let file: File
    private let indexEntries: ArrayList<IndexEntry>
    private let indexOffset: Int64
    private var blockIdx: Int64
    private var blockData: Array<Byte>
    private var offsetInBlock: Int64
    private var done: Bool

    let startKey: ?ByteArray

    init(file: File, indexEntries: ArrayList<IndexEntry>, indexOffset: Int64, startKey: ?ByteArray) {
        this.file = file
        this.indexEntries = indexEntries
        this.indexOffset = indexOffset
        this.startKey = startKey
        this.blockIdx = if (let Some(key) <- startKey) {
            // 定位起始 Data Block
            let n = indexEntries.size
            if (n == 0) {
                0
            } else {
                var lo = 0
                var hi = n - 1
                while (lo < hi) {
                    let mid = lo + (hi - lo + 1) / 2
                    if (indexEntries[mid].firstKey <= key) {
                        lo = mid
                    } else {
                        hi = mid - 1
                    }
                }
                if (lo < n && indexEntries[lo].firstKey <= key) {
                    lo
                } else {
                    0
                }
            }
        } else {
            0
        }
        this.blockData = Array<Byte>(0, repeat: 0u8)
        this.offsetInBlock = 0
        if (indexEntries.size == 0) {
            this.done = true
        } else {
            this.done = false
            loadBlock()
        }
        // 跳过 startKey 之前的条目
        if (let Some(sk) <- startKey) {
            skipBefore(sk)
        }
    }

    /** 跳过所有 key < startKey 的条目 */
    private func skipBefore(startKey: ByteArray): Unit {
        while (true) {
            if (done) { return }
            if (offsetInBlock + 32 > blockData.size) {
                blockIdx++
                if (blockIdx >= indexEntries.size) {
                    done = true
                    return
                }
                loadBlock()
                continue
            }
            let keyLen = readInt64LE(blockData, offsetInBlock)
            let valueLen = readInt64LE(blockData, offsetInBlock + 8)
            let actualValueLen = if (valueLen >= 0) { valueLen } else { 0 }
            let headerEnd2 = offsetInBlock + 32
            var overflow = (headerEnd2 > blockData.size)
            if (!overflow) {
                var remaining = blockData.size - headerEnd2
                if (keyLen > remaining) {
                    overflow = true
                } else {
                    remaining -= keyLen
                    if (actualValueLen > remaining) {
                        overflow = true
                    }
                }
            }
            if (overflow) {
                blockIdx++
                if (blockIdx >= indexEntries.size) {
                    done = true
                    return
                }
                loadBlock()
                continue
            }
            // 提取 key 比较
            var off = offsetInBlock + 32
            let kBuf = Array<Byte>(keyLen, repeat: 0u8)
            for (i in 0..keyLen) {
                kBuf[i] = blockData[off]
                off++
            }
            let k = ByteArray(kBuf)
            if (k >= startKey) {
                return // 找到起始位置
            }
            // 跳过此条目 (已验证不溢出)
            offsetInBlock += 32
            offsetInBlock += keyLen
            offsetInBlock += actualValueLen
        }
    }

    public func next(): Option<(ByteArray, EntryValue)> {
        if (done) {
            return None
        }
        while (true) {
            if (offsetInBlock + 32 > blockData.size) {
                blockIdx++
                if (blockIdx >= indexEntries.size) {
                    done = true
                    return None
                }
                loadBlock()
                continue
            }
            let keyLen = readInt64LE(blockData, offsetInBlock)
            let valueLen = readInt64LE(blockData, offsetInBlock + 8)
            let seq = readInt64LE(blockData, offsetInBlock + 16)
            let expireAt = readInt64LE(blockData, offsetInBlock + 24)
            let actualValueLen = if (valueLen >= 0) { valueLen } else { 0 }
            if (offsetInBlock + 32 > blockData.size) {
                blockIdx++
                if (blockIdx >= indexEntries.size) {
                    done = true
                    return None
                }
                loadBlock()
                continue
            }
            let remaining = blockData.size - offsetInBlock - 32
            if (keyLen > remaining) {
                blockIdx++
                if (blockIdx >= indexEntries.size) {
                    done = true
                    return None
                }
                loadBlock()
                continue
            }
            if (actualValueLen > remaining - keyLen) {
                blockIdx++
                if (blockIdx >= indexEntries.size) {
                    done = true
                    return None
                }
                loadBlock()
                continue
            }
            var off = offsetInBlock + 32
            let kBuf = Array<Byte>(keyLen, repeat: 0u8)
            for (i in 0..keyLen) {
                kBuf[i] = blockData[off]
                off++
            }
            let val = if (valueLen < 0) {
                None<Array<Byte>>
            } else {
                let vBuf = Array<Byte>(valueLen, repeat: 0u8)
                for (i in 0..valueLen) {
                    vBuf[i] = blockData[off]
                    off++
                }
                Some(vBuf)
            }
            let exp = if (expireAt == 0) { None<Int64> } else { Some(expireAt) }
            offsetInBlock = off
            let entry = EntryValue(val, seq, expireAt: exp)
            let pair: (ByteArray, EntryValue) = (ByteArray(kBuf), entry)
            return Some(pair)
        }
        None
    }

    private func loadBlock(): Unit {
        let blockStart = indexEntries[blockIdx].offset
        let blockEnd = if (blockIdx + 1 < indexEntries.size) {
            indexEntries[blockIdx + 1].offset
        } else {
            indexOffset
        }
        let blockSize = blockEnd - blockStart
        blockData = Array<Byte>(blockSize, repeat: 0u8)
        file.seek(SeekPosition.Begin(blockStart))
        file.read(blockData)
        offsetInBlock = 0
    }
}

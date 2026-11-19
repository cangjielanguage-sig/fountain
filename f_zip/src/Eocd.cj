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
package fountain::f_zip

import fountain::f_io.ByteBuffer

/** EOCD（必要时叠加 ZIP64 链）解析出来的三个关键值。 */
internal struct EocdInfo {
    public let entryCount: Int64
    public let cdSize: Int64
    public let cdOffset: Int64
    public let eocdOffset: Int64
    public let eocd64Offset: Option<Int64>

    public init(entryCount: Int64, cdSize: Int64, cdOffset: Int64, eocdOffset: Int64, eocd64Offset: Option<Int64>) {
        this.entryCount = entryCount
        this.cdSize = cdSize
        this.cdOffset = cdOffset
        this.eocdOffset = eocdOffset
        this.eocd64Offset = eocd64Offset
    }
}

/** 把 `want` 字节读满；读不满直接报错（截断文件）。 */
internal func readFullyAt(
    source: EntrySource,
    offset: Int64,
    want: Int64,
    message!: String = "不是有效的 ZIP 文件（未找到中央目录）"
): Array<Byte> {
    if (want <= 0) {
        return Array<Byte>()
    }
    let buf = Array<Byte>(want, repeat: 0)
    let got = source.readAt(offset, buf)
    if (got != want) {
        throw ZipException(message)
    }
    buf
}

/**
 * 定位 EOCD：从尾部窗口（`min(size, 22 + 65535)`）由后向前扫 `0x06054b50`，
 * 对每个候选校验"`22 + 注释长度 == 该候选到文件尾的距离`"，取第一个自洽者。
 *
 * 窗口内扫不到**直接失败**，不退化成全文件扫描——否则"文件损坏"会拖成
 * "读完 2 GB 才报错"。
 */
internal func locateEocd(source: EntrySource): EocdInfo {
    let size = source.size
    if (size < ZipLayout.EOCD_SIZE) {
        throw ZipException("不是有效的 ZIP 文件（未找到中央目录）")
    }
    let window = if (size < ZipLayout.EOCD_WINDOW_LIMIT) {
        size
    } else {
        ZipLayout.EOCD_WINDOW_LIMIT
    }
    let start = size - window
    let tail = Array<Byte>(window, repeat: 0)
    if (source.readAt(start, tail) != window) {
        throw ZipException("不是有效的 ZIP 文件（未找到中央目录）")
    }

    var found: Int64 = -1
    var i = window - ZipLayout.EOCD_SIZE
    while (i >= 0) {
        if (u32At(tail, i) == ZipLayout.SIGNATURE_EOCD) {
            let commentLen = Int64(u16At(tail, i + 20))
            if (ZipLayout.EOCD_SIZE + commentLen == window - i) {
                found = i
                break
            }
        }
        i -= 1
    }
    if (found < 0) {
        throw ZipException("不是有效的 ZIP 文件（未找到中央目录）")
    }

    let eocdOffset = start + found
    // 分卷 / 多磁盘 ZIP 的盘号字段：单卷包必须为 0。这里不像条目数那样有哨兵语义，
    // 非 0 就是"把包拆在了多张盘上"，我们没有跨盘拼接的能力，读到就报。
    let thisDisk = Int64(u16At(tail, found + 4))
    let cdDisk = Int64(u16At(tail, found + 6))
    if (thisDisk != 0 || cdDisk != 0) {
        let disk = if (thisDisk != 0) {
            thisDisk
        } else {
            cdDisk
        }
        throw ZipException("不支持分卷 ZIP（disk ${disk}）")
    }
    let entriesThisDisk = Int64(u16At(tail, found + 8))
    let totalEntries = Int64(u16At(tail, found + 10))
    let cdSize = Int64(u32At(tail, found + 12))
    let cdOffset = Int64(u32At(tail, found + 16))

    let needZip64 = entriesThisDisk == ZipLayout.ZIP64_MAX_U16 || totalEntries == ZipLayout.ZIP64_MAX_U16 ||
        cdSize == ZipLayout.ZIP64_MAX_U32 || cdOffset == ZipLayout.ZIP64_MAX_U32
    if (needZip64) {
        return readZip64Eocd(source, eocdOffset, size)
    }
    checkCdOffset(cdOffset, size)
    EocdInfo(totalEntries, cdSize, cdOffset, eocdOffset, None<Int64>)
}

/**
 * ZIP64 读取链：定位器（`0x07064b50`，20 字节，位于 EOCD 之前）
 * → EOCD64（`0x06064b50`，56 字节）。
 */
internal func readZip64Eocd(source: EntrySource, eocdOffset: Int64, size: Int64): EocdInfo {
    let locatorOffset = eocdOffset - ZipLayout.EOCD64_LOCATOR_SIZE
    if (locatorOffset < 0) {
        throw ZipException("ZIP64 定位器缺失或损坏（EOCD 之前不足 20 字节）")
    }
    let locator = readFullyAt(source, locatorOffset, ZipLayout.EOCD64_LOCATOR_SIZE)
    if (u32At(locator, 0) != ZipLayout.SIGNATURE_EOCD64_LOCATOR) {
        throw ZipException("ZIP64 定位器缺失或损坏（签名不是 0x07064b50）")
    }
    let eocd64Offset = Int64(u64At(locator, 8))
    if (eocd64Offset < 0 || eocd64Offset + ZipLayout.EOCD64_SIZE > size) {
        throw ZipException("ZIP64 EOCD 偏移 ${eocd64Offset} 超出文件长度 ${size}")
    }
    let record = readFullyAt(source, eocd64Offset, ZipLayout.EOCD64_SIZE)
    if (u32At(record, 0) != ZipLayout.SIGNATURE_EOCD64) {
        throw ZipException("ZIP64 EOCD 签名不是 0x06064b50")
    }
    // EOCD64 的 *disk number*（+16）与 *disk with CD*（+20）同样必须是 0。
    let zodDisk = Int64(u32At(record, 16))
    let zodCdDisk = Int64(u32At(record, 20))
    if (zodDisk != 0 || zodCdDisk != 0) {
        let disk = if (zodDisk != 0) {
            zodDisk
        } else {
            zodCdDisk
        }
        throw ZipException("不支持分卷 ZIP（disk ${disk}）")
    }
    // 跳过 sig(4) + size(8) + versionMadeBy(2) + versionNeeded(2) + disk(4) + cdDisk(4) + entriesThisDisk(8)
    let recordBuf = ByteBuffer(record)
    if (!skipBytes(recordBuf, 32)) {
        throw ZipException("ZIP64 EOCD 截断")
    }
    let entryCount = Int64(needValue(readU64LE(recordBuf), "ZIP64 EOCD 截断（total entries）"))
    let cdSize = Int64(needValue(readU64LE(recordBuf), "ZIP64 EOCD 截断（cd size）"))
    let cdOffset = Int64(needValue(readU64LE(recordBuf), "ZIP64 EOCD 截断（cd offset）"))
    checkCdOffset(cdOffset, size)
    EocdInfo(entryCount, cdSize, cdOffset, eocdOffset, Some(eocd64Offset))
}

private func checkCdOffset(cdOffset: Int64, size: Int64): Unit {
    if (cdOffset < 0 || cdOffset > size) {
        throw ZipException("中央目录偏移 ${cdOffset} 超出文件长度 ${size}")
    }
}

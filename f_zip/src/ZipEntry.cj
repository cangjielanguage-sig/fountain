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

import std.time.DateTime

/**
 * 中央目录里的一条条目（只读值类型）。
 *
 * 所有数值一律来自**中央目录**，不来自 local header——bit 3 置位时 local header
 * 的 crc / 大小可能是 0，真实值只在中央目录里。
 *
 * `isDirectory` 由名字是否以 `/` 结尾判断（ZIP 没有独立的目录标志位）。
 * `modifiedAt` 在 DOS 时间为全 0 时是 `None`——"没有时间信息"比伪造一个 1980 年更诚实。
 */
public struct ZipEntry {
    public let name: String
    public let compressedSize: Int64
    public let uncompressedSize: Int64
    public let crc32: UInt32
    public let method: UInt16
    public let isDirectory: Bool
    public let modifiedAt: Option<DateTime>
    public let localHeaderOffset: Int64

    public init(
        name: String,
        compressedSize: Int64,
        uncompressedSize: Int64,
        crc32: UInt32,
        method: UInt16,
        isDirectory: Bool,
        modifiedAt: Option<DateTime>,
        localHeaderOffset: Int64
    ) {
        this.name = name
        this.compressedSize = compressedSize
        this.uncompressedSize = uncompressedSize
        this.crc32 = crc32
        this.method = method
        this.isDirectory = isDirectory
        this.modifiedAt = modifiedAt
        this.localHeaderOffset = localHeaderOffset
    }

    public func toString(): String {
        "ZipEntry(${name}, ${uncompressedSize} bytes)"
    }
}

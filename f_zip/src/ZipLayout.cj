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

/**
 * 压缩方法白名单。只认 Stored 与 Deflate，其余（Deflate64 / BZIP2 / LZMA /
 * Zstandard / XZ / PPMd ...）读取时一律报 `不支持压缩方法 ${method}（${name}）`。
 */
public enum CompressionMethod {
    | Stored
    | Deflate

    /** ZIP 规范里的数值：Stored = 0，Deflate = 8。 */
    public prop value: UInt16 {
        get() {
            match (this) {
                case Stored => 0
                case Deflate => 8
            }
        }
    }

    /** 由规范数值还原；不在白名单内返回 `None`（由调用方决定怎么报错）。 */
    public static func fromValue(value: UInt16): ?CompressionMethod {
        match (value) {
            case 0 => Some(CompressionMethod.Stored)
            case 8 => Some(CompressionMethod.Deflate)
            case _ => None<CompressionMethod>
        }
    }

    public func toString(): String {
        match (this) {
            case Stored => "Stored"
            case Deflate => "Deflate"
        }
    }
}

/**
 * ZIP 容器层的常量表。
 *
 * 全部字段小端；签名一律按"读成 UInt32 后的数值"给出，写的时候由
 * [writeU32LE] 负责拆成 `50 4B 03 04` 这样的字节序列。
 */
internal struct ZipLayout {
    static const SIGNATURE_LOCAL: UInt32 = 0x04034b50
    static const SIGNATURE_CENTRAL: UInt32 = 0x02014b50
    static const SIGNATURE_EOCD: UInt32 = 0x06054b50
    static const SIGNATURE_EOCD64: UInt32 = 0x06064b50
    static const SIGNATURE_EOCD64_LOCATOR: UInt32 = 0x07064b50
    static const SIGNATURE_DATA_DESCRIPTOR: UInt32 = 0x08074b50

    static const LOCAL_HEADER_SIZE: Int64 = 30
    static const CENTRAL_HEADER_SIZE: Int64 = 46
    static const EOCD_SIZE: Int64 = 22
    static const EOCD64_SIZE: Int64 = 56
    static const EOCD64_LOCATOR_SIZE: Int64 = 20
    static const DATA_DESCRIPTOR_SIZE: Int64 = 24

    /** ZIP64 extended information extra field 的 header id。 */
    static const ZIP64_EXTRA_ID: UInt16 = 0x0001

    static const SENTINEL_U16: UInt16 = 0xFFFF
    static const SENTINEL_U32: UInt32 = 0xFFFFFFFF

    /** 普通条目所需的最低解压版本。 */
    static const VERSION_DEFAULT: UInt16 = 20
    /** 用到 ZIP64（含流式条目的 descriptor 占位）时的最低解压版本。 */
    static const VERSION_ZIP64: UInt16 = 45

    static const FLAG_ENCRYPTED: UInt16 = 0x0001
    static const FLAG_DATA_DESCRIPTOR: UInt16 = 0x0008
    static const FLAG_STRONG_ENCRYPTION: UInt16 = 0x0040
    static const FLAG_UTF8_NAME: UInt16 = 0x0800

    /** "version made by"：高字节 3 = Unix，低字节 30 = 3.0。目录条目靠它让 unzip 认 mode。 */
    static const VERSION_MADE_BY_UNIX: UInt16 = 0x031E

    /** 目录条目的 external attributes：Unix mode `040755 << 16`。 */
    static const EXTERNAL_ATTRIBUTES_DIRECTORY: UInt32 = 0x41ED0000

    /** EOCD 尾部窗口上界：22 字节 EOCD + 65535 字节注释。 */
    static const EOCD_WINDOW_LIMIT: Int64 = EOCD_SIZE + 65535

    /** 条目数 / 大小 / 偏移超过它就升级 ZIP64。 */
    static const ZIP64_MAX_U16: Int64 = 0xFFFF
    static const ZIP64_MAX_U32: Int64 = 0xFFFFFFFF
}

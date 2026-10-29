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

import std.io.{OutputStream, SeekPosition}
import fountain::f_io.ByteBuffer

/**
 * 显式小端读写原语（内部的，不进公开 API）。
 *
 * 四条硬约定：
 * 1. 越界返回 `None` / `false`，**读游标不位移**；
 * 2. 校验实际读到的字节数，短读不补零、直接判失败；
 * 3. 小端一律显式，不依赖任何"默认端序"的 API；
 * 4. 只服务 ZIP，不进公开 API。
 *
 * 读侧的越界判定一律"先看还剩多少，不够就不动游标"——`f_io.ByteBuffer.readByte()`
 * 在耗尽时会 `clear()` 掉整块缓冲，一旦真的读到末尾就再也回滚不了。
 */
internal func leRemaining(buf: ByteBuffer): Int64 {
    buf.writeOffset - buf.readOffset
}

/** 定长读：不足 `n` 字节时返回 `None`，游标不动。 */
internal func readBytes(buf: ByteBuffer, n: Int64): ?Array<Byte> {
    if (n < 0 || leRemaining(buf) < n) {
        return None<Array<Byte>>
    }
    if (n == 0) {
        return Some(Array<Byte>())
    }
    let dst = Array<Byte>(n, repeat: 0)
    let got = buf.read(dst)
    if (got != n) {
        return None<Array<Byte>>
    }
    Some(dst)
}

/** 跳过 `n` 字节；越界返回 `false` 且游标不动。 */
internal func skipBytes(buf: ByteBuffer, n: Int64): Bool {
    if (n < 0 || leRemaining(buf) < n) {
        return false
    }
    buf.seekReading(Current(n))
    true
}

internal func readU16LE(buf: ByteBuffer): ?UInt16 {
    if (let Some(b) <- readBytes(buf, 2)) {
        return Some(UInt16(b[0]) | (UInt16(b[1]) << 8))
    }
    None<UInt16>
}

internal func readU32LE(buf: ByteBuffer): ?UInt32 {
    if (let Some(b) <- readBytes(buf, 4)) {
        return Some(UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24))
    }
    None<UInt32>
}

internal func readU64LE(buf: ByteBuffer): ?UInt64 {
    if (let Some(b) <- readBytes(buf, 8)) {
        var v: UInt64 = 0
        for (i in 0..8) {
            v = v | (UInt64(b[i]) << (8 * i))
        }
        return Some(v)
    }
    None<UInt64>
}

internal func writeU16LE(out: OutputStream, v: UInt16): Unit {
    let b = Array<Byte>(2, repeat: 0)
    b[0] = UInt8(v & 0xFF)
    b[1] = UInt8((v >> 8) & 0xFF)
    out.write(b)
}

internal func writeU32LE(out: OutputStream, v: UInt32): Unit {
    let b = Array<Byte>(4, repeat: 0)
    b[0] = UInt8(v & 0xFF)
    b[1] = UInt8((v >> 8) & 0xFF)
    b[2] = UInt8((v >> 16) & 0xFF)
    b[3] = UInt8((v >> 24) & 0xFF)
    out.write(b)
}

internal func writeU64LE(out: OutputStream, v: UInt64): Unit {
    let b = Array<Byte>(8, repeat: 0)
    for (i in 0..8) {
        b[i] = UInt8((v >> (8 * i)) & 0xFF)
    }
    out.write(b)
}

/** 把小端 16/32/64 位整数编码成字节数组（extra field 之类需要先拼后写的场景）。 */
internal func u16LEBytes(v: UInt16): Array<Byte> {
    let b = Array<Byte>(2, repeat: 0)
    b[0] = UInt8(v & 0xFF)
    b[1] = UInt8((v >> 8) & 0xFF)
    b
}

internal func u32LEBytes(v: UInt32): Array<Byte> {
    let b = Array<Byte>(4, repeat: 0)
    b[0] = UInt8(v & 0xFF)
    b[1] = UInt8((v >> 8) & 0xFF)
    b[2] = UInt8((v >> 16) & 0xFF)
    b[3] = UInt8((v >> 24) & 0xFF)
    b
}

internal func u64LEBytes(v: UInt64): Array<Byte> {
    let b = Array<Byte>(8, repeat: 0)
    for (i in 0..8) {
        b[i] = UInt8((v >> (8 * i)) & 0xFF)
    }
    b
}

/** 取值或抛 `ZipException`：解析固定结构时把所有截断都变成带上下文的错误。 */
internal func needValue<T>(value: Option<T>, message: String): T {
    if (let Some(v) <- value) {
        return v
    }
    throw ZipException(message)
}

/** 逐段拼接字节数组（仓颉的 `Array` 没有 `+`）。 */
internal func concatBytes(parts: Array<Array<Byte>>): Array<Byte> {
    var total: Int64 = 0
    for (p in parts) {
        total += p.size
    }
    let out = Array<Byte>(total, repeat: 0)
    var at: Int64 = 0
    for (p in parts) {
        p.copyTo(out, 0, at, p.size)
        at += p.size
    }
    out
}

/** 从已经整块读入的字节数组里按固定偏移取小端值（解析头部时用）。 */
internal func u16At(b: Array<Byte>, offset: Int64): UInt16 {
    UInt16(b[offset]) | (UInt16(b[offset + 1]) << 8)
}

internal func u32At(b: Array<Byte>, offset: Int64): UInt32 {
    UInt32(b[offset]) | (UInt32(b[offset + 1]) << 8) | (UInt32(b[offset + 2]) << 16) |
        (UInt32(b[offset + 3]) << 24)
}

internal func u64At(b: Array<Byte>, offset: Int64): UInt64 {
    var v: UInt64 = 0
    for (i in 0..8) {
        v = v | (UInt64(b[offset + i]) << (8 * i))
    }
    v
}


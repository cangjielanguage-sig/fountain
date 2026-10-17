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
package fountain::f_jit.bytecode

import std.collection.ArrayList

/**
 * 显式小端（LE）编解码原语 —— design-m1 §3.3.2、plan-m1 S2.2。
 *
 * 权威 = `doc/jit-bytecode-m1.md` §11.2「编码与端序」：
 *
 * > 字节码是**字节串，固定小端（LE）**：多字节操作数按 LE 写出/读出，**必须显式解码**；
 * > 禁止 `memcpy`、指针强转、`memcpy` 式的结构体覆盖来解读字节码。这样同一份字节码在 BE
 * > 主机上也能被解释器正确执行。指令自身无对齐要求，全部指令定长；解码逐字节读取。
 *
 * 因此本文件里**没有**任何 `unsafe`、指针、结构体覆盖：所有多字节值都是「逐字节取、按权移位
 * 相加」（读）与「逐字节取低 8 位、右移」（写）。有符号值与无符号值之间的互转也走**显式
 * 算术**（见 `u32ToI32` / `i64ToU64` 等），不依赖宿主对「超范围整数转换」的隐式行为。
 *
 * **归属**：读侧全部在 `ByteReader`、写侧全部在 `ByteWriter`（两者都是**有状态游标**——读位置
 * / 写缓冲——故用 class）。`FbcHeader.read/write`、`FbcReader`、`BytecodeBuilder` 都复用这一对
 * 类型；除它们之外不再有第二套字节读写原语。
 */

// ---- 有符号 ↔ 无符号位模式互转（显式算术，不依赖宿主转换语义）----

/** `u32` 位模式 → `i32`（补码解释）。 */
internal func u32ToI32(u: UInt32): Int32 {
    if (u >= 0x80000000u32) {
        Int32(u - 0x80000000u32) - 2147483647 - 1
    } else {
        Int32(u)
    }
}

/** `i32` → `u32` 位模式（补码表示）。 */
internal func i32ToU32(v: Int32): UInt32 {
    if (v < 0) {
        UInt32(v + 2147483647 + 1) + 0x80000000u32
    } else {
        UInt32(v)
    }
}

/** `u64` 位模式 → `i64`（补码解释）。 */
internal func u64ToI64(u: UInt64): Int64 {
    if (u >= 0x8000000000000000u64) {
        Int64(u - 0x8000000000000000u64) - 9223372036854775807 - 1
    } else {
        Int64(u)
    }
}

/** `i64` → `u64` 位模式（补码表示）。 */
internal func i64ToU64(v: Int64): UInt64 {
    if (v < 0) {
        UInt64(v + 9223372036854775807 + 1) + 0x8000000000000000u64
    } else {
        UInt64(v)
    }
}

/**
 * 读游标：**逐字节显式小端解码**。
 *
 * 越界读一律经 `rejectFormat` 抛出容器格式类错误（18），**不产生越界内存访问**（spec
 * 「显式小端编解码」的越界场景）。
 */
public class ByteReader {
    private let data: Array<UInt8>
    private var pos: Int64
    private let end: Int64

    public init(data: Array<UInt8>) {
        this.data = data
        this.pos = 0
        this.end = data.size
    }

    /** 从 `off` 处起读（段解析用：各段起点不同）。 */
    public init(data: Array<UInt8>, off: Int64) {
        this.data = data
        this.pos = off
        this.end = data.size
        if (off < 0 || off > data.size) {
            rejectFormat('ByteReader 起始偏移越界: off=${off}, size=${data.size}')
        }
    }

    /** 当前读位置。 */
    public func offset(): Int64 {
        this.pos
    }

    /** 剩余可读字节数。 */
    public func remaining(): Int64 {
        this.end - this.pos
    }

    /** 跳到绝对位置 `to`（段内跳转 / 重读目录）。 */
    public func seek(to: Int64): Unit {
        if (to < 0 || to > this.end) {
            rejectFormat('ByteReader seek 越界: to=${to}, end=${this.end}')
        }
        this.pos = to
    }

    private func need(n: Int64): Unit {
        if (this.pos + n > this.end) {
            rejectFormat('ByteReader 越界读: 需要 ${n} 字节, 剩余 ${this.end - this.pos} 字节')
        }
    }

    /** 读 1 字节。 */
    public func u8(): UInt8 {
        need(1)
        let v = this.data[this.pos]
        this.pos = this.pos + 1
        v
    }

    /** 读 2 字节小端。 */
    public func u16(): UInt16 {
        need(2)
        let b0 = UInt16(this.data[this.pos])
        let b1 = UInt16(this.data[this.pos + 1])
        this.pos = this.pos + 2
        b0 | (b1 << 8)
    }

    /** 读 4 字节小端（无符号）。 */
    public func u32(): UInt32 {
        need(4)
        let b0 = UInt32(this.data[this.pos])
        let b1 = UInt32(this.data[this.pos + 1])
        let b2 = UInt32(this.data[this.pos + 2])
        let b3 = UInt32(this.data[this.pos + 3])
        this.pos = this.pos + 4
        b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }

    /** 读 4 字节小端（有符号）。 */
    public func i32(): Int32 {
        u32ToI32(u32())
    }

    /** 读 8 字节小端（无符号）。 */
    public func u64(): UInt64 {
        need(8)
        var acc: UInt64 = 0u64
        for (i in 0..8) {
            acc = acc | (UInt64(this.data[this.pos + i]) << (8 * i))
        }
        this.pos = this.pos + 8
        acc
    }

    /** 读 8 字节小端（有符号）。 */
    public func i64(): Int64 {
        u64ToI64(u64())
    }

    /**
     * 读 8 字节小端并返回其**位模式**（`Float64` 的 IEEE754 binary64 表示，§11.2）。
     *
     * 加载器据此校验 canonical NaN（§11.3），故这里不做任何浮点运算、也不做规范化。
     */
    public func f64bits(): UInt64 {
        u64()
    }

    /** 读 `n` 字节（段 / 字符串载荷）。 */
    public func bytes(n: Int64): Array<UInt8> {
        if (n < 0) {
            rejectFormat('ByteReader bytes 长度非法: ${n}')
        }
        need(n)
        let out = Array<UInt8>(n, repeat: 0u8)
        for (i in 0..n) {
            out[i] = this.data[this.pos + i]
        }
        this.pos = this.pos + n
        out
    }
}

/**
 * 写缓冲：**逐字节显式小端写出**。
 *
 * 与 `ByteReader` 严格互为逆运算（§11.2）；`take()` 取出产物后缓冲不复用（避免别名）。
 */
public class ByteWriter {
    private let buf: ArrayList<UInt8>

    public init() {
        this.buf = ArrayList<UInt8>()
    }

    /** 写出 1 字节。 */
    public func wU8(v: UInt8): Unit {
        this.buf.add(v)
    }

    /** 写出 2 字节小端。 */
    public func wU16(v: UInt16): Unit {
        this.buf.add(UInt8(v & 0xFFu16))
        this.buf.add(UInt8((v >> 8) & 0xFFu16))
    }

    /** 写出 4 字节小端（无符号）。 */
    public func wU32(v: UInt32): Unit {
        this.buf.add(UInt8(v & 0xFFu32))
        this.buf.add(UInt8((v >> 8) & 0xFFu32))
        this.buf.add(UInt8((v >> 16) & 0xFFu32))
        this.buf.add(UInt8((v >> 24) & 0xFFu32))
    }

    /** 写出 4 字节小端（有符号）。 */
    public func wI32(v: Int32): Unit {
        wU32(i32ToU32(v))
    }

    /** 写出 8 字节小端（无符号）。 */
    public func wU64(v: UInt64): Unit {
        for (i in 0..8) {
            this.buf.add(UInt8((v >> (8 * i)) & 0xFFu64))
        }
    }

    /** 写出 8 字节小端（有符号）。 */
    public func wI64(v: Int64): Unit {
        wU64(i64ToU64(v))
    }

    /** 追加一段原始字节（段拼接、字符串载荷）。 */
    public func wBytes(bs: Array<UInt8>): Unit {
        for (b in bs) {
            this.buf.add(b)
        }
    }

    /** 已写出字节数（段长 / 偏移计算用）。 */
    public func size(): Int64 {
        this.buf.size
    }

    /** 取出产物（快照，不共享内部缓冲）。 */
    public func take(): Array<UInt8> {
        this.buf.toArray()
    }
}

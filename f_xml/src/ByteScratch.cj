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
package fountain::f_xml

/**
 * 只增不减的 UTF-8 字节累积器：`reset()` 只把长度置 0，容量留作下次复用。
 *
 * 与 `StringGenerator` 的区别只有两点：
 * 1. 不释放底层数组（`f_base` 的行为不改，这里自建一份）；
 * 2. `bytes()` 给的是**零拷贝视图**，名字驻留的逐字节比对用它；
 *    `StringGenerator.unsafeBytes()` 返回的是按 `size` 截好的新数组，每次比对都分配。
 *
 * 输出与 `StringGenerator` 逐字节相同（`ByteScratch_test` 对拍）。
 */
internal class ByteScratch {
    private static let kInitialCapacity: Int64 = 256
    /** 实例序号：给「复用缓冲实例数恒定」的结构性断言一个可比较的身份。 */
    private static var nextId: Int64 = 0
    let id: Int64
    /** 非 ASCII 码点的 4 字节暂存（复用，避免每字符一次小分配）。 */
    private let enc = Array<Byte>(4, repeat: 0)
    private var buf = Array<Byte>(ByteScratch.kInitialCapacity, repeat: 0)
    private var len: Int64 = 0

    init() {
        ByteScratch.nextId++
        this.id = ByteScratch.nextId
    }

    prop size: Int64 {
        get() {
            this.len
        }
    }

    /** 清空但保留容量。 */
    func reset(): ByteScratch {
        this.len = 0
        this
    }

    private func ensure(extra: Int64): Unit {
        let need = this.len + extra
        if (need <= this.buf.size) {
            return
        }
        var capacity = this.buf.size
        while (capacity < need) {
            capacity *= 2
        }
        let grown = Array<Byte>(capacity, repeat: 0)
        for (i in 0..this.len) {
            grown[i] = this.buf[i]
        }
        this.buf = grown
    }

    /** ASCII 直接写字节（`码点即字节`）。 */
    func putAscii(b: Int64): Unit {
        this.ensure(1)
        this.buf[this.len] = UInt8(b)
        this.len++
    }

    /** 任意码点：ASCII 走直写，其余走 `Rune.intoUtf8Array`（与 `StringGenerator` 同一份编码）。 */
    func putCp(cp: Int64): Unit {
        if (cp < 0x80) {
            this.putAscii(cp)
            return
        }
        this.ensure(4)
        let n = Rune.intoUtf8Array(Rune(cp), this.enc, 0)
        for (i in 0..n) {
            this.buf[this.len + i] = this.enc[i]
        }
        this.len += n
    }

    /** 底层数组的零拷贝视图：只有 `[0..size)` 有效。 */
    func bytes(): Array<Byte> {
        this.buf
    }

    func toUtf8String(): String {
        let end = this.len
        unsafe {
            String.fromUtf8Unchecked(this.buf[0..end])
        }
    }
}

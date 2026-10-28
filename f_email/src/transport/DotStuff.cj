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
package fountain::f_email.transport

import std.collection.ArrayList
import std.io.{InputStream, OutputStream}

/**
 * SMTP `DATA` 写侧：行首 `.` 加倍，所有行以 CRLF 结束。
 *
 * 逐字节状态机，不假设一次 `write` 覆盖整行，因此调用方按任意块大小写都正确。
 * 同时做换行归一（裸 LF / 裸 CR → CRLF）——SMTP 的 DATA 必须是规范 CRLF，
 * 依赖调用方传入正确的换行风格迟早会出错。
 *
 * `finish()` 的语义：空正文只写 `.\r\n`；最后一行没有 CRLF 时先补 CRLF 再写 `.\r\n`。
 */
public class DotStuffWriter <: OutputStream {
    private let output: OutputStream
    private var atLineStart = true
    private var pendingCr = false
    private var wroteAny = false
    private var finished = false

    public init(output: OutputStream) {
        this.output = output
    }

    public func write(buffer: Array<Byte>): Unit {
        if (finished) {
            throw IllegalStateException("DotStuffWriter 已 finish")
        }
        if (buffer.size == 0) {
            return
        }
        let out = ArrayList<Byte>()
        for (b in buffer) {
            if (pendingCr) {
                pendingCr = false
                emitCrlf(out)
                if (b == b'\n') {
                    continue
                }
            }
            if (b == b'\r') {
                pendingCr = true
                continue
            }
            if (b == b'\n') {
                emitCrlf(out)
                continue
            }
            if (atLineStart && b == b'.') {
                out.add(b'.')
            }
            out.add(b)
            atLineStart = false
            wroteAny = true
        }
        flushBuffer(out)
    }

    /** 结束正文：补齐 CRLF 并写出结束行。 */
    public func finish(): Unit {
        if (finished) {
            return
        }
        finished = true
        let out = ArrayList<Byte>()
        if (pendingCr) {
            pendingCr = false
            emitCrlf(out)
        }
        if (!wroteAny) {
            out.add(b'.')
            emitCrlf(out)
        } else if (atLineStart) {
            out.add(b'.')
            emitCrlf(out)
        } else {
            emitCrlf(out)
            out.add(b'.')
            emitCrlf(out)
        }
        flushBuffer(out)
    }

    private func emitCrlf(out: ArrayList<Byte>): Unit {
        out.add(b'\r')
        out.add(b'\n')
        atLineStart = true
        wroteAny = true
    }

    private func flushBuffer(out: ArrayList<Byte>): Unit {
        if (out.size == 0) {
            return
        }
        output.write(out.toArray())
    }
}

/**
 * POP3 / SMTP 读侧：去掉行首多余的一个 `.`，遇到单独一行 `.` 结束。
 *
 * 逐字节状态机，只记"是否在行首"，因此正文行可以任意长——行上限只作用于协议控制行，
 * 不作用于正文（`LineChannel.readLine` 不参与这里的读取）。
 *
 * 宽容策略：行首出现 `.` 后跟的不是 `.` / CRLF / LF 时，按字面保留，不把流吞掉。
 */
public class DotUnstuffReader <: InputStream {
    private let input: InputStream
    private var buffer = Array<Byte>(8192, repeat: 0)
    private var pos = 0
    private var limit = 0
    private var atLineStart = true
    private var done = false

    public init(input: InputStream) {
        this.input = input
    }

    public func read(target: Array<Byte>): Int64 {
        if (target.size == 0 || done) {
            return 0
        }
        var written = 0
        while (written < target.size && !done) {
            if (!ensure(1)) {
                done = true
                break
            }
            let b = peek(0)
            if (!atLineStart || b != b'.') {
                consume(1)
                target[written] = b
                written += 1
                atLineStart = (b == b'\n')
                continue
            }
            // 行首的点：需要看下一个字节
            if (!ensure(2)) {
                consume(1)
                target[written] = b'.'
                written += 1
                atLineStart = false
                done = true
                break
            }
            let next = peek(1)
            if (next == b'.') {
                consume(2)
                target[written] = b'.'
                written += 1
                atLineStart = false
            } else if (next == b'\n') {
                consume(2)
                done = true
            } else if (next == b'\r') {
                if (ensure(3) && peek(2) == b'\n') {
                    consume(3)
                    done = true
                } else {
                    // 不是结束行：按字面保留
                    consume(1)
                    target[written] = b'.'
                    written += 1
                    atLineStart = false
                }
            } else {
                consume(1)
                target[written] = b'.'
                written += 1
                atLineStart = false
            }
        }
        written
    }

    // ---------- 内部缓冲 ----------

    private func peek(offset: Int64): Byte {
        buffer[pos + offset]
    }

    private func consume(count: Int64): Unit {
        pos += count
    }

    /** 保证缓冲里至少有 `need` 个未消费字节；返回 false 表示 EOF。 */
    private func ensure(need: Int64): Bool {
        if (limit - pos >= need) {
            return true
        }
        // 把剩余字节挪到开头
        let remaining = limit - pos
        if (pos > 0) {
            for (i in 0..remaining) {
                buffer[i] = buffer[pos + i]
            }
            pos = 0
            limit = remaining
        }
        while (limit < need) {
            if (limit == buffer.size) {
                // need 大于当前缓冲（只可能是 need=3 的边界情况），扩容
                let bigger = Array<Byte>(limit * 2, repeat: 0)
                for (i in 0..limit) {
                    bigger[i] = buffer[i]
                }
                buffer = bigger
            }
            let want = buffer.size - limit
            let tmp = Array<Byte>(want, repeat: 0)
            let n = input.read(tmp)
            if (n <= 0) {
                return false
            }
            for (i in 0..n) {
                buffer[limit + i] = tmp[i]
            }
            limit += n
        }
        true
    }
}

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
import std.net.SocketTimeoutException
import fountain::f_email.{IoStage, LimitKind, MailIoException, MailLimitException, MailProtocolException}

/**
 * 行通道：字节行，不是 String 行。
 *
 * 返回 `Array<Byte>` 的理由：POP3 `RETR` 正文是任意 8 位字节，IMAP literal 长度是字节数；
 * 先 `String` 化就是先猜编码。协议控制行在调用方拿到字节后再做 ASCII 解码。
 *
 * 三个必须记住的约束：
 *
 * 1. `writeLine` 是**全链路唯一的 CRLF 注入防线**：参数里出现 `\r` / `\n` 直接抛异常，一个字节都不写；
 * 2. `readExact` 必须消费行缓冲里的残留——IMAP literal 紧跟在 `{n}` 所在行的 CRLF 之后；
 * 3. `buffered=false` 时按单字节读，供 STARTTLS 升级前使用，避免把 TLS 握手字节吞进缓冲区。
 */
public class LineChannel <: InputStream & Resource {
    private let input: InputStream
    private let output: OutputStream
    private let maxLine: Int64
    private let buffered: Bool
    private let trace: ?MailTrace
    private let timeouts: ?IoTimeout
    private let onFatal: ?() -> Unit

    private var pending = ArrayList<Byte>()
    private var pendingPos = 0
    private var eof = false
    private var closed = false
    private var replaced = false
    private var sensitive = false
    private var deadline: ?Deadline = None

    public init(
        input: InputStream,
        output: OutputStream,
        maxLine!: Int64 = 4096,
        buffered!: Bool = true,
        trace!: ?MailTrace = None,
        timeouts!: ?IoTimeout = None,
        onFatal!: ?() -> Unit = None
    ) {
        this.input = input
        this.output = output
        this.maxLine = maxLine
        this.buffered = buffered
        this.trace = trace
        this.timeouts = timeouts
        this.onFatal = onFatal
    }

    // ---------- 协议层用的控制开关 ----------

    /** 设置本次命令的总超时；每次读写前折算成剩余时长。 */
    public func withDeadline(timeout: Duration): Unit {
        deadline = Deadline(timeout)
    }

    /** 清除命令总超时（用于 IDLE：静默不算超时）。 */
    public func clearDeadline(): Unit {
        deadline = None
    }

    /** 进入凭据敏感模式：期间写出的每一行在跟踪里都是 `<redacted>`。 */
    public func beginSensitive(): Unit {
        sensitive = true
    }

    public func endSensitive(): Unit {
        sensitive = false
    }

    /** 被 STARTTLS 替换：旧通道的任何读取都必须失败，而不是静默读到废弃的明文流。 */
    func invalidate(): Unit {
        replaced = true
    }

    func isReplaced(): Bool {
        replaced
    }

    // ---------- 读 ----------

    /**
     * 读一行，返回不含行结束符的字节。
     *
     * `\r\n` 与裸 `\n` 都接受（裸 `\n` 记一次告警）；EOF 返回 `None`（无残留时）。
     * 超过 `maxLine` 抛 [MailLimitException] 并关闭连接。
     */
    public func readLine(): ?Array<Byte> {
        ensureUsable()
        var searchFrom = pendingPos
        while (true) {
            // 在已缓冲的字节里找 '\n'
            var i = searchFrom
            while (i < pending.size) {
                if (pending[i] == b'\n') {
                    if (i - pendingPos > maxLine) {
                        let actual = i - pendingPos
                        fatal()
                        throw MailLimitException(LimitKind.Line, maxLine, actual)
                    }
                    var end = i
                    if (end > pendingPos && pending[end - 1] == b'\r') {
                        end -= 1
                    } else if (i > pendingPos) {
                        protocolWarning("收到裸 LF 行结束符")
                    }
                    let line = slicePending(pendingPos, end)
                    pendingPos = i + 1
                    compactIfNeeded()
                    traceLine(r'S', line)
                    return Some(line)
                }
                i += 1
            }
            if (i - pendingPos > maxLine) {
                let actual = i - pendingPos
                fatal()
                throw MailLimitException(LimitKind.Line, maxLine, actual)
            }
            searchFrom = pending.size
            if (!fill()) {
                // EOF：把残留当最后一行返回；彻底空则 None
                if (pendingPos >= pending.size) {
                    eof = true
                    return None
                }
                let line = slicePending(pendingPos, pending.size)
                pendingPos = pending.size
                eof = true
                traceLine(r'S', line)
                return Some(line)
            }
        }
        return None
    }

    /**
     * 精确读 `count` 字节（IMAP literal）。
     *
     * 先消费行缓冲残留，再直接从底层流读。不足 `count` 就 EOF 抛 [MailIoException]。
     */
    public func readExact(count: Int64): Array<Byte> {
        ensureUsable()
        if (count == 0) {
            return Array<Byte>()
        }
        let result = Array<Byte>(count, repeat: 0)
        var written = 0
        // 1. 缓冲区残留
        let available = pending.size - pendingPos
        if (available > 0) {
            let take = if (available < count) {
                available
            } else {
                count
            }
            for (i in 0..take) {
                result[i] = pending[pendingPos + i]
            }
            pendingPos += take
            written = take
            compactIfNeeded()
        }
        // 2. 直接从底层流读：分块读再拷贝，避免 Array 切片是拷贝带来的额外峰值
        let chunk = Array<Byte>(65536, repeat: 0)
        while (written < count) {
            applyReadTimeout()
            let want = if (count - written < chunk.size) {
                count - written
            } else {
                chunk.size
            }
            let tmp = Array<Byte>(want, repeat: 0)
            let n = try {
                input.read(tmp)
            } catch (e: SocketTimeoutException) {
                throw timeoutException()
            } catch (e: Exception) {
                throw ioFailure(IoStage.Read, e)
            }
            if (n <= 0) {
                throw ioFailure(IoStage.Read, Exception("literal 读取中断：期望 ${count}，实际 ${written}"))
            }
            for (i in 0..n) {
                result[written + i] = tmp[i]
            }
            written += n
            traceBytes(r'S', n)
        }
        result
    }

    /** 普通字节流读取：先消费缓冲残留，不足时直接读底层流。 */
    public func read(buffer: Array<Byte>): Int64 {
        ensureUsable()
        if (buffer.size == 0) {
            return 0
        }
        let available = pending.size - pendingPos
        if (available > 0) {
            let take = if (available < buffer.size) {
                available
            } else {
                buffer.size
            }
            for (i in 0..take) {
                buffer[i] = pending[pendingPos + i]
            }
            pendingPos += take
            compactIfNeeded()
            return take
        }
        applyReadTimeout()
        let n = try {
            input.read(buffer)
        } catch (e: SocketTimeoutException) {
            throw timeoutException()
        } catch (e: Exception) {
            throw ioFailure(IoStage.Read, e)
        }
        if (n > 0) {
            traceBytes(r'S', n)
        } else if (n == 0) {
            eof = true
        }
        n
    }

    // ---------- 写 ----------

    /** 写一行，自动补 CRLF；参数含 `\r` 或 `\n` 直接抛异常且不写出任何字节。 */
    public func writeLine(line: String): Unit {
        writeLine(line.toArray())
    }

    public func writeLine(line: Array<Byte>): Unit {
        ensureUsable()
        for (b in line) {
            if (b == b'\r' || b == b'\n') {
                throw MailProtocolException("命令参数含 CR/LF，拒绝写出（CRLF 注入防线）")
            }
        }
        let out = Array<Byte>(line.size + 2, repeat: 0)
        for (i in 0..line.size) {
            out[i] = line[i]
        }
        out[line.size] = b'\r'
        out[line.size + 1] = b'\n'
        writeBytes(out)
        traceLine(r'C', line)
    }

    public func write(bytes: Array<Byte>): Unit {
        ensureUsable()
        writeBytes(bytes)
        if (bytes.size > 0) {
            traceBytes(r'C', bytes.size)
        }
    }

    public func flush(): Unit {
        // 底层是裸 socket 时无需 flush；保留接口供 BufferedOutputStream 之类的实现使用。
    }

    public func close(): Unit {
        closed = true
        if (let Some(f) <- onFatal) {
            f()
        }
    }

    public func isClosed(): Bool {
        closed || replaced
    }

    // ---------- 内部 ----------

    private func ensureUsable(): Unit {
        if (replaced) {
            throw MailProtocolException("channel replaced by STARTTLS")
        }
        if (closed) {
            throw MailProtocolException("channel is closed")
        }
    }

    private func writeBytes(bytes: Array<Byte>): Unit {
        if (bytes.size == 0) {
            return
        }
        applyWriteTimeout()
        try {
            output.write(bytes)
        } catch (e: SocketTimeoutException) {
            throw timeoutException()
        } catch (e: Exception) {
            throw ioFailure(IoStage.Write, e)
        }
    }

    private func applyReadTimeout(): Unit {
        if (let Some(t) <- timeouts) {
            if (let Some(d) <- deadline) {
                let remaining = d.remaining()
                if (remaining <= Duration.Zero) {
                    throw timeoutException()
                }
                t.setReadTimeout(remaining)
            } else {
                t.setReadTimeout(None)
            }
        }
    }

    private func applyWriteTimeout(): Unit {
        if (let Some(t) <- timeouts) {
            if (let Some(d) <- deadline) {
                let remaining = d.remaining()
                if (remaining <= Duration.Zero) {
                    throw timeoutException()
                }
                t.setWriteTimeout(remaining)
            } else {
                t.setWriteTimeout(None)
            }
        }
    }

    private func fill(): Bool {
        if (eof) {
            return false
        }
        let size: Int64 = if (buffered) {
            8192
        } else {
            1
        }
        let tmp = Array<Byte>(size, repeat: 0)
        applyReadTimeout()
        let n = try {
            input.read(tmp)
        } catch (e: SocketTimeoutException) {
            throw timeoutException()
        } catch (e: Exception) {
            throw ioFailure(IoStage.Read, e)
        }
        if (n <= 0) {
            eof = true
            return false
        }
        for (i in 0..n) {
            pending.add(tmp[i])
        }
        traceBytes(r'S', n)
        true
    }

    private func slicePending(from: Int64, to: Int64): Array<Byte> {
        let n = to - from
        let out = Array<Byte>(n, repeat: 0)
        for (i in 0..n) {
            out[i] = pending[from + i]
        }
        out
    }

    private func compactIfNeeded(): Unit {
        if (pendingPos >= 8192) {
            let rest = ArrayList<Byte>()
            for (i in pendingPos..pending.size) {
                rest.add(pending[i])
            }
            pending = rest
            pendingPos = 0
        }
    }

    private func fatal(): Unit {
        closed = true
        if (let Some(f) <- onFatal) {
            f()
        }
    }

    private func timeoutException(): MailIoException {
        fatal()
        MailIoException(IoStage.Timeout, "命令总超时")
    }

    private func ioFailure(stage: IoStage, causedBy: Exception): MailIoException {
        fatal()
        MailIoException(stage, "IO 失败：${causedBy.message}", causedBy)
    }

    private func traceLine(direction: Rune, bytes: Array<Byte>): Unit {
        if (let Some(t) <- trace) {
            let text = try {
                String.fromUtf8(bytes)
            } catch (_: Exception) {
                return
            }
            if (sensitive && direction == r'C') {
                t.onLine(direction, "<redacted>")
            } else {
                t.onLine(direction, redactLine(text))
            }
        }
    }

    private func traceBytes(direction: Rune, count: Int64): Unit {
        if (let Some(t) <- trace) {
            t.onBytes(direction, count)
        }
    }

    private func protocolWarning(message: String): Unit {
        // 告警走跟踪通道；没有跟踪时不额外分配任何东西。
        if (let Some(t) <- trace) {
            t.onLine(r'W', message)
        }
    }

}

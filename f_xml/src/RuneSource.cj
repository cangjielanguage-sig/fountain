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

import std.io.InputStream
import cangjie_tpc::charset4cj.charset.TextReader

/**
 * 字符来源：把字节流适配成「按字符读取」。
 *
 * `peek(offset)` 只保证 `offset ≤ 4` 时有效（XML 最长前瞻是 `<![CDATA[` / `<!--` 这类 4 字符前缀），
 * 实现用可增长环形缓冲，不承诺无限缓冲。
 *
 * **不提供 `byteOffset`**：`TextReader` 不暴露底层字节位置，硬算出来的值跨缓冲边界就是错的。
 */
public interface RuneSource {
    /** 向前看第 `offset` 个字符（0 = 当前），不移动游标。 */
    func peek(offset: Int64): ?Rune

    /** 消费并返回当前字符。 */
    func advance(): ?Rune

    /** 下一个待读字符的 1-based 行列号。 */
    func position(): SourcePosition

    /**
     * `peek` 的热路径版本：直接给码点，`-1` 表示流结束。
     *
     * 仓颉的 `Option` 是引用类型，`?Rune` 每字符一次分配；词法器逐字符扫描时必须走这两个
     * 版本，否则吞吐会被分配压到 1 MB/s 以下。语义与 `peek` / `advance` 完全一致。
     */
    func peekFast(offset: Int64): Int64

    func advanceFast(): Int64
}

/** 一次块填充的结果：`count` 个有效码点；`error` 非 `None` 表示「这 `count` 个之后就是坏字节」。 */
internal struct BlockFill {
    let count: Int64
    let error: ?Exception

    init(count: Int64, error!: ?Exception = None) {
        this.count = count
        this.error = error
    }
}

/** 码点块容量：`bufSize` 是字节块，码点数不会超过它；下限 64 保证 `peek(≤ 8)`。 */
internal func blockCapacityOf(bufSize: Int64): Int64 {
    if (bufSize < 64) {
        return 64
    }
    if (bufSize > 1024 * 1024) {
        return 1024 * 1024
    }
    bufSize
}

/**
 * 三个具体实现的公共块缓冲与行列号推进逻辑。
 *
 * 活动路径由 `LineWindow` 通过 `readCodePointBlock` 驱动：码点直接写进调用方的
 * `Array<Int32>`，本类的 `ownBlock` 只在调用方**直接**使用 `RuneSource` 的
 * `peek` / `advance` 时才惰性分配。
 */
public abstract class BufferedRuneSource <: RuneSource {
    private let capacity: Int64
    private var ownBlock: ?Array<Int32> = None
    private var ownPos: Int64 = 0
    private var ownLen: Int64 = 0
    private var ownError: ?Exception = None
    private var ownEof: Bool = false
    private var line: Int64 = 1
    private var column: Int64 = 1
    /** 解码游标：填充时推进，用来算「坏字节自身」的行列号，与消费游标分离。 */
    private var decLine: Int64 = 1
    private var decColumn: Int64 = 1

    /** 块填充次数（`count > 0` 计一次）。内部可读，仅供用例断言「确实按块解码」。 */
    var blocksFilled: Int64 = 0
    /** 累计产出的码点数。 */
    var codepointsYielded: Int64 = 0

    /** 兼容无参 `super()`：容量取默认块大小。 */
    protected init() {
        this.capacity = blockCapacityOf(8192)
    }

    protected init(bufSize: Int64) {
        this.capacity = blockCapacityOf(bufSize)
    }

    /** 从底层取下一个字符写进 `pulledRune`；`false` 表示流结束。 */
    protected func pull(): Bool

    /** `pull()` 的落点：避免每字符一个 `Option` 分配。 */
    protected var pulledRune: Rune = r'\0'

    internal func blockCapacity(): Int64 {
        this.capacity
    }

    /** 自有块是否已分配：`LineWindow` 驱动的路径必须保持 `false`（不分配第二份块）。 */
    internal func hasOwnBlock(): Bool {
        this.ownBlock.isSome()
    }

    /**
     * 把至多 `capacity` 个码点写进 `dest[start..]`。
     *
     * 内置的 UTF-8 / UTF-16 / UTF-32 源走各自的批量路径；`CharsetRuneSource` 与第三方
     * 子类走默认的 `pull()` 循环。解码异常装进 `BlockFill` 延迟到消费点抛出，避免超前
     * 解码把「坏字节之前的事件」提前吞掉。
     *
     * 说明：`internal` 成员在仓颉里不能是 `open`，而 `protected open` 又不允许返回
     * `internal` 类型（`BlockFill`），所以这里用「基类按具体类型分派」代替虚方法——
     * 对外仍然是 `internal` seam，不新增任何公开 / 受保护签名。
     */
    internal func decodeInto(dest: Array<Int32>, start: Int64, capacity: Int64): BlockFill {
        match (this) {
            case source: Utf8RuneSource => source.decodeBatch(dest, start, capacity)
            case source: BlockRuneSource => source.decodeBatch(dest, start, capacity)
            case _ => this.decodeViaPull(dest, start, capacity)
        }
    }

    private func decodeViaPull(dest: Array<Int32>, start: Int64, capacity: Int64): BlockFill {
        var i = start
        let end = start + capacity
        try {
            while (i < end) {
                if (!this.pull()) {
                    break
                }
                dest[i] = Int32(this.pulledRune.position())
                i++
            }
        } catch (e: Exception) {
            return BlockFill(i - start, error: Some(e))
        }
        BlockFill(i - start)
    }

    /** 块读入口：`LineWindow` 通过它把码点直接写进自己的数组（不分配第二份块）。 */
    internal func readCodePointBlock(dest: Array<Int32>, start: Int64, capacity: Int64): BlockFill {
        this.finishFill(this.decodeInto(dest, start, capacity), dest, start)
    }

    /** 推进解码游标、累计计数，并给没有位置的解码异常补上「坏字符自身」的行列号。 */
    private func finishFill(fill: BlockFill, dest: Array<Int32>, start: Int64): BlockFill {
        for (i in 0..fill.count) {
            if (dest[start + i] == 0x0A) {
                this.decLine++
                this.decColumn = 1
            } else {
                this.decColumn++
            }
        }
        this.codepointsYielded += fill.count
        if (fill.count > 0) {
            this.blocksFilled++
        }
        match (fill.error) {
            case Some(e) => BlockFill(fill.count, error: Some(this.positionedError(e)))
            case None => fill
        }
    }

    /**
     * 解码异常补位置：只有「位置未知」的 `XmlException` 才包装（补一次行列号），
     * 其他异常类型（如 charset4cj 自己的异常）原样保留，不包装、不改消息。
     */
    private func positionedError(error: Exception): Exception {
        match (error) {
            case e: XmlException =>
                if (e.line == 0 && e.column == 0) {
                    XmlException(e.message, this.decLine, this.decColumn)
                } else {
                    e
                }
            case e => e
        }
    }

    private func ownBuffer(): Array<Int32> {
        match (this.ownBlock) {
            case Some(block) => block
            case None =>
                let block = Array<Int32>(this.capacity, repeat: 0)
                this.ownBlock = Some(block)
                block
        }
    }

    /** 自有块补充到至少 `target` 个可读码点；`false` 表示不再有数据。 */
    private func ensureOwn(target: Int64): Bool {
        while (this.ownLen - this.ownPos < target && this.ownError.isNone() && !this.ownEof) {
            let block = this.ownBuffer()
            if (this.ownPos > 0) {
                let remain = this.ownLen - this.ownPos
                for (i in 0..remain) {
                    block[i] = block[this.ownPos + i]
                }
                this.ownPos = 0
                this.ownLen = remain
            }
            let fill = this.finishFill(this.decodeInto(block, this.ownLen, this.capacity - this.ownLen), block, this.ownLen)
            this.ownLen += fill.count
            if (fill.count == 0) {
                if (fill.error.isSome()) {
                    this.ownError = fill.error
                } else {
                    this.ownEof = true
                }
            }
        }
        this.ownLen - this.ownPos >= target
    }

    private func raiseOwnError(): Unit {
        match (this.ownError) {
            case Some(e) => throw e
            case None => ()
        }
    }

    /** 向前看第 `offset` 个字符的码点；`-1` 表示流结束。**热路径**，不走 `Option`。 */
    public func peekFast(offset: Int64): Int64 {
        if (offset < 0 || offset > 8) {
            return -1
        }
        if (!this.ensureOwn(offset + 1)) {
            if (this.ownError.isSome() && this.ownLen - this.ownPos == offset) {
                this.raiseOwnError()
            }
            return -1
        }
        if (this.ownPos + offset == this.ownLen && this.ownError.isSome()) {
            this.raiseOwnError()
        }
        Int64(this.ownBuffer()[this.ownPos + offset])
    }

    /** 消费当前字符并返回码点；`-1` 表示流结束。**热路径**，不走 `Option`。 */
    public func advanceFast(): Int64 {
        if (!this.ensureOwn(1)) {
            this.raiseOwnError()
            return -1
        }
        let cp = Int64(this.ownBuffer()[this.ownPos])
        this.ownPos++
        if (cp == 0x0A) {
            this.line++
            this.column = 1
        } else {
            this.column++
        }
        cp
    }

    public func peek(offset: Int64): ?Rune {
        let cp = this.peekFast(offset)
        if (cp < 0) {
            None
        } else {
            Some(Rune(cp))
        }
    }

    public func advance(): ?Rune {
        let cp = this.advanceFast()
        if (cp < 0) {
            None
        } else {
            Some(Rune(cp))
        }
    }

    public func position(): SourcePosition {
        SourcePosition(this.line, this.column)
    }
}

/**
 * UTF-8 字符来源。
 *
 * - `InvalidByteMode.Strict`：走 `std.io.StringReader`，合法输入的逐字符输出与它完全一致；
 * - `InvalidByteMode.Replace`：走自研 `ByteDecoder`，按 RFC 3629 maximal subpart 产出 `U+FFFD`。
 *
 * 两条路径**互不替代**：`Strict` 不经过 `Replace` 解码器。
 */
public class Utf8RuneSource <: BufferedRuneSource {
    private let decoder: ByteDecoder
    private let strict: Bool

    public init(input: InputStream, mode!: InvalidByteMode = InvalidByteMode.Strict, bufSize!: Int64 = 8192) {
        super(bufSize)
        this.strict = mode == InvalidByteMode.Strict
        this.decoder = ByteDecoder(
            input,
            if (this.strict) { ByteCodec.Utf8Strict } else { ByteCodec.Utf8Replace },
            bufSize
        )
    }

    /** 批量解码：连续 ASCII 一次搬运，多字节走既有单字符路径。 */
    internal func decodeBatch(dest: Array<Int32>, start: Int64, capacity: Int64): BlockFill {
        this.decoder.decodeBlock(dest, start, capacity)
    }

    protected func pull(): Bool {
        try {
            let cp = this.decoder.next()
            if (cp < 0) {
                false
            } else {
                this.pulledRune = Rune(cp)
                true
            }
        } catch (e: XmlException) {
            // 解码器不知道行列号，这里补上。
            let pos = this.position()
            throw XmlException(e.message, pos.line, pos.column)
        }
    }
}

/** 非 UTF-8 的多字节编码（GBK 等）：走 `charset4cj.TextReader`。 */
public class CharsetRuneSource <: BufferedRuneSource {
    private let reader: TextReader

    public init(input: InputStream, charset!: Charset = Charsets.UTF8, bufSize!: Int64 = 8192) {
        super(bufSize)
        this.reader = TextReader(input, charset: charset, bufSize: bufSize)
    }

    protected func pull(): Bool {
        match (this.reader.read()) {
            case Some(r) =>
                this.pulledRune = r
                true
            case None => false
        }
    }
}

/** 固定块解码器承载的编码。 */
internal enum ByteCodec {
    | Utf8Strict
    | Utf8Replace
    | Utf16Le
    | Utf16Be
    | Utf32Le
    | Utf32Be
}

/**
 * UTF-16 / UTF-32 的固定块字符来源。
 *
 * 不能用 `readln()`：它按**字节**找 `0x0A`，而 UTF-16 里 `U+0A00` 的低字节就是 `0x0A`，
 * 会在字符中间断行。固定块解码由 `ByteDecoder` 负责块尾回退（≤3 字节）。
 */
public class BlockRuneSource <: BufferedRuneSource {
    private let decoder: ByteDecoder

    internal init(input: InputStream, codec!: ByteCodec, bufSize!: Int64 = 8192) {
        super(bufSize)
        this.decoder = ByteDecoder(input, codec, bufSize)
    }

    /** UTF-16 / UTF-32：块内仍逐个 `next()`，但只发生在填充，Lexer 热路径看不到。 */
    internal func decodeBatch(dest: Array<Int32>, start: Int64, capacity: Int64): BlockFill {
        this.decoder.decodeBlock(dest, start, capacity)
    }

    protected func pull(): Bool {
        let cp = this.decoder.next()
        if (cp < 0) {
            false
        } else {
            this.pulledRune = Rune(cp)
            true
        }
    }
}

/**
 * 共享字节层：固定块读取 + 块尾回退 + 坏字节分类。
 *
 * `Utf8ReplaceDecoder` 与 UTF-16/32 解码共用它，因此块边界处的「半个字符」只在
 * 这里处理一次。回退量恒 ≤ 3 字节（UTF-8 最多 4 字节、UTF-16 最多 4 字节一个代理对、
 * UTF-32 恒 4 字节）。
 */
internal class ByteDecoder {
    private let reader: ByteReader
    private let codec: ByteCodec
    private var truncatedReported: Bool = false

    init(input: InputStream, codec: ByteCodec, bufSize: Int64) {
        this.reader = ByteReader(input, bufSize)
        this.codec = codec
    }

    /** 下一个码点；`-1` 表示流结束（热路径不分配 `Option`）。 */
    func next(): Int64 {
        match (this.codec) {
            case Utf8Strict => nextUtf8(true)
            case Utf8Replace => nextUtf8(false)
            case Utf16Le => nextUtf16(true)
            case Utf16Be => nextUtf16(false)
            case Utf32Le => nextUtf32(true)
            case Utf32Be => nextUtf32(false)
        }
    }

    /**
     * 按块解码：把至多 `capacity` 个码点写进 `dest[start..]`。
     *
     * UTF-8 的连续 ASCII 段一次搬运（不做每字节一次 `ensure` / 分支），多字节序列仍走
     * `nextUtf8`（含块尾回退）。UTF-16 / UTF-32 块内循环 `next()`。
     * 解码异常不向上抛，装进 `BlockFill.error` 延迟到消费点。
     */
    func decodeBlock(dest: Array<Int32>, start: Int64, capacity: Int64): BlockFill {
        var i = start
        let end = start + capacity
        try {
            match (this.codec) {
                case Utf8Strict | Utf8Replace =>
                    let strict = match (this.codec) {
                        case Utf8Strict => true
                        case _ => false
                    }
                    while (i < end) {
                        if (!this.reader.ensure(1)) {
                            break
                        }
                        let n = this.reader.copyAsciiRun(dest, i, end - i)
                        if (n > 0) {
                            i += n
                            continue
                        }
                        let cp = this.nextUtf8(strict)
                        if (cp < 0) {
                            break
                        }
                        dest[i] = Int32(cp)
                        i++
                    }
                case _ =>
                    while (i < end) {
                        let cp = this.next()
                        if (cp < 0) {
                            break
                        }
                        dest[i] = Int32(cp)
                        i++
                    }
            }
        } catch (e: Exception) {
            return BlockFill(i - start, error: Some(e))
        }
        BlockFill(i - start)
    }

    private func nextUtf8(strict: Bool): Int64 {
        if (!this.reader.ensure(1)) {
            return -1
        }
        let b0 = Int64(this.reader.peekByte(0))
        if (b0 < 0x80) {
            this.reader.consume(1)
            return b0
        }
        if (b0 < 0xC2 || b0 > 0xF4) {
            if (strict) {
                throw XmlException("非法 UTF-8 字节序列（字节偏移 ${this.reader.consumedBytes()}）")
            }
            this.reader.consume(1)
            return 0xFFFD
        }
        let need: Int64 = if (b0 < 0xE0) {
            2
        } else if (b0 < 0xF0) {
            3
        } else {
            4
        }
        if (this.reader.ensure(need)) {
            // 整个序列都在缓冲里，逐字节校验后再决定消费多少。
            let cp = decodeCompleteUtf8(b0, need, this.reader, strict)
            if (cp < 0) {
                return 0xFFFD
            }
            return cp
        }
        // 真 EOF 处的截断序列：整段剩余字节就是一个 maximal subpart。
        if (strict) {
            throw XmlException("非法 UTF-8 字节序列：序列被截断（字节偏移 ${this.reader.consumedBytes()}）")
        }
        let remaining = this.reader.available()
        this.reader.consume(remaining)
        0xFFFD
    }

    /**
     * 在「整个序列都在缓冲里」时判定；成功则消费并返回码点，失败则按 maximal subpart
     * 消费后缀并返回 `None`（由调用方产出 `U+FFFD`）。
     */
    private func decodeCompleteUtf8(b0: Int64, need: Int64, reader: ByteReader, strict: Bool): Int64 {
        var cp: Int64 = 0
        var validLen: Int64 = 1
        if (need == 2) {
            let b1 = Int64(reader.peekByte(1))
            if (!isContinuation(b1)) {
                if (strict) {
                    throw XmlException("非法 UTF-8 字节序列（字节偏移 ${reader.consumedBytes()}）")
                }
                reader.consume(1)
                return -1
            }
            cp = ((b0 & 0x1F) << 6) | (b1 & 0x3F)
            validLen = 2
        } else if (need == 3) {
            let b1 = Int64(reader.peekByte(1))
            let lowBound: Int64 = if (b0 == 0xE0) { 0xA0 } else { 0x80 }
            let highBound: Int64 = if (b0 == 0xED) { 0x9F } else { 0xBF }
            if (b1 < lowBound || b1 > highBound) {
                if (strict) {
                    throw XmlException("非法 UTF-8 字节序列（字节偏移 ${reader.consumedBytes()}）")
                }
                consumeBroken(reader, 1, need)
                return -1
            }
            let b2 = Int64(reader.peekByte(2))
            if (!isContinuation(b2)) {
                if (strict) {
                    throw XmlException("非法 UTF-8 字节序列（字节偏移 ${reader.consumedBytes()}）")
                }
                consumeBroken(reader, 2, need)
                return -1
            }
            cp = ((b0 & 0x0F) << 12) | ((b1 & 0x3F) << 6) | (b2 & 0x3F)
            validLen = 3
        } else {
            let b1 = Int64(reader.peekByte(1))
            let lowBound: Int64 = if (b0 == 0xF0) { 0x90 } else { 0x80 }
            let highBound: Int64 = if (b0 == 0xF4) { 0x8F } else { 0xBF }
            if (b1 < lowBound || b1 > highBound) {
                if (strict) {
                    throw XmlException("非法 UTF-8 字节序列（字节偏移 ${reader.consumedBytes()}）")
                }
                consumeBroken(reader, 1, need)
                return -1
            }
            let b2 = Int64(reader.peekByte(2))
            if (!isContinuation(b2)) {
                if (strict) {
                    throw XmlException("非法 UTF-8 字节序列（字节偏移 ${reader.consumedBytes()}）")
                }
                consumeBroken(reader, 2, need)
                return -1
            }
            let b3 = Int64(reader.peekByte(3))
            if (!isContinuation(b3)) {
                if (strict) {
                    throw XmlException("非法 UTF-8 字节序列（字节偏移 ${reader.consumedBytes()}）")
                }
                consumeBroken(reader, 3, need)
                return -1
            }
            cp = ((b0 & 0x07) << 18) | ((b1 & 0x3F) << 12) | ((b2 & 0x3F) << 6) | (b3 & 0x3F)
            validLen = 4
        }
        reader.consume(validLen)
        cp
    }

    private func nextUtf16(littleEndian: Bool): Int64 {
        if (!this.reader.ensure(2)) {
            return truncatedOrNone()
        }
        let first = readUnit16(this.reader, 0, littleEndian)
        if (first >= 0xD800 && first <= 0xDBFF) {
            if (this.reader.ensure(4)) {
                let second = readUnit16(this.reader, 2, littleEndian)
                if (second >= 0xDC00 && second <= 0xDFFF) {
                    this.reader.consume(4)
                    return 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
                }
            }
            this.reader.consume(2)
            return 0xFFFD
        }
        if (first >= 0xDC00 && first <= 0xDFFF) {
            this.reader.consume(2)
            return 0xFFFD
        }
        this.reader.consume(2)
        first
    }

    private func nextUtf32(littleEndian: Bool): Int64 {
        if (!this.reader.ensure(4)) {
            return truncatedOrNone()
        }
        let value = readUnit32(this.reader, littleEndian)
        this.reader.consume(4)
        if (value > 0x10FFFF || (value >= 0xD800 && value <= 0xDFFF)) {
            return 0xFFFD
        }
        value
    }

    /** 块尾不足一个完整字符：整体消费剩余字节并只报一次 `U+FFFD`。 */
    private func truncatedOrNone(): Int64 {
        let remaining = this.reader.available()
        if (remaining == 0) {
            return -1
        }
        if (this.truncatedReported) {
            this.reader.consume(remaining)
            return -1
        }
        this.truncatedReported = true
        this.reader.consume(remaining)
        0xFFFD
    }

    /**
     * 消费一个坏序列：`already` 字节是合法前缀，后续只要还是续字节就一并吃掉。
     *
     * 这样 `E0 80` / `F0 80 80` 这类「截断并带续字节」的片段各只产出一个 `U+FFFD`，
     * 且不会把后面的正常字符卷进来。
     */
    private func consumeBroken(reader: ByteReader, already: Int64, need: Int64): Unit {
        var n = already
        while (n < need && reader.available() > n && isContinuation(Int64(reader.peekByte(n)))) {
            n++
        }
        reader.consume(n)
    }

    private func isContinuation(b: Int64): Bool {
        b >= 0x80 && b <= 0xBF
    }

    private func readUnit16(reader: ByteReader, offset: Int64, littleEndian: Bool): Int64 {
        let b0 = Int64(reader.peekByte(offset))
        let b1 = Int64(reader.peekByte(offset + 1))
        if (littleEndian) {
            (b1 << 8) | b0
        } else {
            (b0 << 8) | b1
        }
    }

    private func readUnit32(reader: ByteReader, littleEndian: Bool): Int64 {
        let b0 = Int64(reader.peekByte(0))
        let b1 = Int64(reader.peekByte(1))
        let b2 = Int64(reader.peekByte(2))
        let b3 = Int64(reader.peekByte(3))
        if (littleEndian) {
            (b3 << 24) | (b2 << 16) | (b1 << 8) | b0
        } else {
            (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
        }
    }
}

/** 固定块字节读取器：只在需要时补齐，块尾未消费的字节自动留到下一次。 */
internal class ByteReader {
    private let input: InputStream
    private var buf: Array<Byte>
    private var pos: Int64 = 0
    private var len: Int64 = 0
    private var eof: Bool = false
    private var consumed: Int64 = 0
    private let scratch: Array<Byte>

    init(input: InputStream, bufSize: Int64) {
        this.input = input
        let size = if (bufSize < 8) { 8 } else { bufSize }
        this.buf = Array<Byte>(size, repeat: 0)
        this.scratch = Array<Byte>(size, repeat: 0)
    }

    func available(): Int64 {
        this.len - this.pos
    }

    func consumedBytes(): Int64 {
        this.consumed
    }

    func peekByte(offset: Int64): Byte {
        this.buf[this.pos + offset]
    }

    /**
     * 把当前连续的 ASCII 字节一次搬进 `dest`，返回搬运数量。
     *
     * 走私有字段而不是 `consume()`，避免每字节一次函数调用；非 ASCII 字节留给
     * `ByteDecoder.nextUtf8` 的多字节路径。
     */
    func copyAsciiRun(dest: Array<Int32>, dstStart: Int64, limit: Int64): Int64 {
        var written: Int64 = 0
        var index = dstStart
        while (this.pos < this.len && written < limit && UInt32(this.buf[this.pos]) < 0x80) {
            dest[index] = Int32(this.buf[this.pos])
            this.pos++
            this.consumed++
            written++
            index++
        }
        if (this.pos == this.len) {
            this.pos = 0
            this.len = 0
        }
        written
    }

    func consume(count: Int64): Unit {
        this.pos += count
        this.consumed += count
        if (this.pos == this.len) {
            this.pos = 0
            this.len = 0
        }
    }

    /** 保证缓冲内至少有 `count` 字节可读；返回是否满足。 */
    func ensure(count: Int64): Bool {
        while (this.available() < count && !this.eof) {
            fill()
        }
        this.available() >= count
    }

    private func fill(): Unit {
        if (this.pos > 0) {
            let remaining = this.available()
            for (i in 0..remaining) {
                this.buf[i] = this.buf[this.pos + i]
            }
            this.pos = 0
            this.len = remaining
        }
        let n = this.input.read(this.scratch)
        if (n <= 0) {
            this.eof = true
            return
        }
        if (this.len + n > this.buf.size) {
            // bufSize 小于单个字符宽度（测试里会有 bufSize = 4/8），按需扩容。
            var capacity = this.buf.size * 2
            if (capacity < this.len + n) {
                capacity = this.len + n
            }
            let grown = Array<Byte>(capacity, repeat: 0)
            for (i in 0..this.len) {
                grown[i] = this.buf[i]
            }
            this.buf = grown
        }
        for (i in 0..n) {
            this.buf[this.len + i] = this.scratch[i]
        }
        this.len += n
    }
}

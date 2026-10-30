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
 * 行拼接与行尾归一，同时是活动路径上**唯一**的码点块缓冲。
 *
 * 三条约定（设计文档 §2.4）：
 * 1. `readln()` 的 `Some("")` 是**空行**，要补 `\n`；`None` 是**流结束**，不补。
 * 2. `\r\n` 与孤立 `\r` 归一成 `\n`，且只在字符层做**一次**（两层都做得 `\r\r\n`）。
 * 3. 不假设「一行等于一个 token」：属性值、注释、CDATA 都可跨行。
 *
 * 归一发生在**填充**（`fillOnce`）时；行列号只在**消费**（`advanceFast`）时推进。
 * 源是 `BufferedRuneSource` 时走块读入口（码点直接写进本类的数组，不分配第二份块）；
 * 否则（第三方直接实现 `RuneSource`）回退逐字符填充，结果完全相同。
 */
public class LineWindow {
    private let source: RuneSource
    private var block = Array<Int32>(64, repeat: 0)
    private var pos: Int64 = 0
    private var len: Int64 = 0
    /** 已产出 `len` 个码点后就是坏字节；消费到该位置时才抛（解码超前读不能提前报错）。 */
    private var pendingError: ?Exception = None
    /** `\r` 在块尾、`\n` 在下一块开头时吞掉那个 `\n`。 */
    private var pendingSkipLf: Bool = false
    private var eof: Bool = false
    private var sized: Bool = false
    private var line: Int64 = 1
    private var column: Int64 = 1

    public init(source: RuneSource) {
        this.source = source
    }

    /** 首次填充时按源的块容量扩容（第三方源保持 64 码点）。 */
    private func ensureSized(): Unit {
        if (this.sized) {
            return
        }
        this.sized = true
        match (this.source) {
            case s: BufferedRuneSource =>
                let capacity = s.blockCapacity()
                if (capacity > this.block.size) {
                    this.block = Array<Int32>(capacity, repeat: 0)
                }
            case _ => ()
        }
    }

    /** 从源取至多 `capacity` 个原始码点（未归一）。 */
    private func readRaw(dest: Array<Int32>, start: Int64, capacity: Int64): BlockFill {
        match (this.source) {
            case s: BufferedRuneSource => s.readCodePointBlock(dest, start, capacity)
            case _ =>
                var i = start
                let end = start + capacity
                while (i < end) {
                    let cp = this.source.advanceFast()
                    if (cp < 0) {
                        break
                    }
                    dest[i] = Int32(cp)
                    i++
                }
                BlockFill(i - start)
        }
    }

    /** 填充一次并就地归一；返回是否产出了新码点。 */
    private func fillOnce(): Bool {
        this.ensureSized()
        if (this.len >= this.block.size) {
            return false
        }
        let fill = this.readRaw(this.block, this.len, this.block.size - this.len)
        var write = this.len
        var read = this.len
        let rawEnd = this.len + fill.count
        while (read < rawEnd) {
            let cp = this.block[read]
            read++
            if (this.pendingSkipLf) {
                this.pendingSkipLf = false
                if (cp == 0x0A) {
                    continue
                }
            }
            if (cp == 0x0D) {
                this.block[write] = 0x0A
                write++
                this.pendingSkipLf = true
            } else {
                this.block[write] = cp
                write++
            }
        }
        let produced = write - this.len
        this.len = write
        if (fill.count == 0) {
            this.eof = true
            if (fill.error.isSome()) {
                this.pendingError = fill.error
            }
        }
        produced > 0
    }

    /** 保证缓冲内有 `target` 个可读码点；`false` 表示 EOF 或错误点在此之前。 */
    private func ensure(target: Int64): Bool {
        while (this.len - this.pos < target) {
            if (this.pos > 0) {
                let remain = this.len - this.pos
                for (i in 0..remain) {
                    this.block[i] = this.block[this.pos + i]
                }
                this.pos = 0
                this.len = remain
            }
            if (this.len >= target) {
                break
            }
            if (this.eof || this.pendingError.isSome()) {
                break
            }
            if (this.len >= this.block.size) {
                break
            }
            this.fillOnce()
        }
        this.len - this.pos >= target
    }

    private func raisePendingError(): Unit {
        match (this.pendingError) {
            case Some(e) => throw e
            case None => ()
        }
    }

    /** 向前看第 `offset` 个字符的码点；`-1` 表示流结束。热路径不分配 `Option`。 */
    public func peekFast(offset: Int64): Int64 {
        // 快路径：块内命中时不做 ensure 调用与边界循环（词法器逐字符调用的主路径）。
        if (offset >= 0 && offset <= 8) {
            let index = this.pos + offset
            if (index < this.len) {
                return Int64(this.block[index])
            }
        }
        return this.peekFastSlow(offset)
    }

    private func peekFastSlow(offset: Int64): Int64 {
        if (offset < 0 || offset > 8) {
            return -1
        }
        if (!this.ensure(offset + 1)) {
            if (this.pendingError.isSome()) {
                this.raisePendingError()
            }
            return -1
        }
        Int64(this.block[this.pos + offset])
    }

    /** 消费当前字符并返回码点；`-1` 表示流结束。热路径不分配 `Option`。 */
    public func advanceFast(): Int64 {
        // 快路径：块内命中时只做下标推进与行列号更新，不进入 ensure。
        if (this.pos < this.len) {
            let cp = Int64(this.block[this.pos])
            this.pos++
            if (cp == 0x0A) {
                this.line++
                this.column = 1
            } else {
                this.column++
            }
            return cp
        }
        return this.advanceFastSlow()
    }

    private func advanceFastSlow(): Int64 {
        if (!this.ensure(1)) {
            if (this.pendingError.isSome()) {
                this.raisePendingError()
            }
            return -1
        }
        let cp = Int64(this.block[this.pos])
        this.pos++
        if (cp == 0x0A) {
            this.line++
            this.column = 1
        } else {
            this.column++
        }
        cp
    }

    // ------------------------------------------------------------ 块视图（internal）
    //
    // **失效规则**：`ensure` 会把未消费的尾部搬到数组头部并把 `pos` 归零，所以
    // `cpAt` / `asciiRunLength` 的下标只在「上一次 `runAvailable()` 之后、下一次
    // `runAvailable()` 之前」有效。批量路径的顺序固定为
    // `runAvailable` → `asciiRunLength` / `cpAt` 拷贝 → `skipRun`，绝不跨 `runAvailable`
    // 持有下标。加这些成员是为了让词法器整段消费 ASCII，而不是逐字符 `peekCp` / `advanceCp`。

    /**
     * 触发一次 `ensure(1)`，返回当前块内可直接消费的码点数；EOF 时返回 0。
     *
     * 语义与 `peekFast(0)` 对齐：不足且存在 `pendingError` 时抛错，不返回 0 伪装 EOF。
     */
    internal func runAvailable(): Int64 {
        if (!this.ensure(1)) {
            if (this.pendingError.isSome()) {
                this.raisePendingError()
            }
            return 0
        }
        this.len - this.pos
    }

    /** 相对当前游标的码点；调用方保证 `i < runAvailable()`。不 ensure、不改状态。 */
    internal func cpAt(i: Int64): Int64 {
        Int64(this.block[this.pos + i])
    }

    /**
     * 从当前游标起、连续满足「码点 < 0x80 且 `mask[cp] == false`」的码点数。
     *
     * 不 ensure：调用方先 `runAvailable()` 取快照，保证期间不触发压缩或重填。
     */
    internal func asciiRunLength(mask: Array<Bool>): Int64 {
        let end = this.len
        var i = this.pos
        while (i < end) {
            let cp = Int64(this.block[i])
            if (cp >= 0x80 || mask[cp]) {
                break
            }
            i++
        }
        i - this.pos
    }

    /** 等价于连续调用 `n` 次 `advanceFast`：行列号推进逐字一致（`\n` 行+1、列归 1）。 */
    internal func skipRun(n: Int64): Unit {
        if (n <= 0) {
            return
        }
        let end = this.pos + n
        var hasNewline = false
        var i = this.pos
        while (i < end) {
            if (this.block[i] == 0x0A) {
                hasNewline = true
                break
            }
            i++
        }
        if (!hasNewline) {
            this.column += n
        } else {
            var line = this.line
            var column = this.column
            var k = this.pos
            while (k < end) {
                if (this.block[k] == 0x0A) {
                    line++
                    column = 1
                } else {
                    column++
                }
                k++
            }
            this.line = line
            this.column = column
        }
        this.pos = end
    }

    /** 向前看第 `offset` 个字符（0 = 当前），不移动游标。 */
    public func peek(offset: Int64): ?Rune {
        let cp = this.peekFast(offset)
        if (cp < 0) {
            None
        } else {
            Some(Rune(cp))
        }
    }

    /** 消费并返回当前字符。 */
    public func advance(): ?Rune {
        let cp = this.advanceFast()
        if (cp < 0) {
            None
        } else {
            Some(Rune(cp))
        }
    }

    /** 下一个待读字符的 1-based 行列号。 */
    public func position(): SourcePosition {
        SourcePosition(this.line, this.column)
    }

/** 当前字符是否已到流末尾。 */
    public func isEof(): Bool {
        this.peekFast(0) < 0
    }
}

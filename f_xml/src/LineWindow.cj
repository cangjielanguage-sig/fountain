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
 * 行拼接与行尾归一。
 *
 * 三条约定（设计文档 §2.4）：
 * 1. `readln()` 的 `Some("")` 是**空行**，要补 `\n`；`None` 是**流结束**，不补。
 * 2. `\r\n` 与孤立 `\r` 归一成 `\n`，且只在字符层做**一次**（两层都做得 `\r\r\n`）。
 * 3. 不假设「一行等于一个 token」：属性值、注释、CDATA 都可跨行。
 *
 * 归一在本类完成；`RuneSource` 保持原始字符。
 */
public class LineWindow {
    private let source: RuneSource
    private let ring = Array<Rune>(16, repeat: r'\0')
    private var head: Int64 = 0
    private var count: Int64 = 0
    private var line: Int64 = 1
    private var column: Int64 = 1

    public init(source: RuneSource) {
        this.source = source
    }

    private func pullNormalized(): Int64 {
        let cp = this.source.advanceFast()
        if (cp < 0) {
            return -1
        }
        if (cp == 0x0D) {
            // \r\n 只吃一次；孤立 \r 也归一成 \n。
            if (this.source.peekFast(0) == 0x0A) {
                this.source.advanceFast()
            }
            this.pulled = 0x0A
            return 0
        }
        this.pulled = cp
        0
    }

    private var pulled: Int64 = 0

    private func fillTo(target: Int64): Bool {
        while (this.count < target) {
            if (this.pullNormalized() < 0) {
                return false
            }
            this.ring[(this.head + this.count) & 15] = Rune(this.pulled)
            this.count++
        }
        true
    }

    /** 向前看第 `offset` 个字符的码点；`-1` 表示流结束。热路径不分配 `Option`。 */
    public func peekFast(offset: Int64): Int64 {
        if (offset < 0 || offset > 8 || !this.fillTo(offset + 1)) {
            return -1
        }
        this.ring[(this.head + offset) & 15].position()
    }

    /** 消费当前字符并返回码点；`-1` 表示流结束。热路径不分配 `Option`。 */
    public func advanceFast(): Int64 {
        if (this.count == 0 && !this.fillTo(1)) {
            return -1
        }
        let r = this.ring[this.head]
        this.head = (this.head + 1) & 15
        this.count--
        if (r == r'\n') {
            this.line++
            this.column = 1
        } else {
            this.column++
        }
        r.position()
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

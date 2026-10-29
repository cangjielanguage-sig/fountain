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

import std.collection.ArrayList

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
    private let pending = ArrayList<Rune>()
    private var head: Int64 = 0
    private var line: Int64 = 1
    private var column: Int64 = 1

    public init(source: RuneSource) {
        this.source = source
    }

    private func pullNormalized(): ?Rune {
        match (this.source.advance()) {
            case Some(r) =>
                if (r == r'\r') {
                    // \r\n 只吃一次；孤立 \r 也归一成 \n。
                    if (let Some(next) <- this.source.peek(0)) {
                        if (next == r'\n') {
                            this.source.advance()
                        }
                    }
                    Some(r'\n')
                } else {
                    Some(r)
                }
            case None => None
        }
    }

    private func fillTo(count: Int64): Bool {
        while (this.pending.size - this.head < count) {
            match (this.pullNormalized()) {
                case Some(r) => this.pending.add(r)
                case None => return false
            }
        }
        true
    }

    private func compact(): Unit {
        if (this.head >= this.pending.size) {
            this.pending.clear()
            this.head = 0
        } else if (this.head > 64) {
            let rest = ArrayList<Rune>()
            for (i in this.head..this.pending.size) {
                rest.add(this.pending[i])
            }
            this.pending.clear()
            for (r in rest) {
                this.pending.add(r)
            }
            this.head = 0
        }
    }

    /** 向前看第 `offset` 个字符（0 = 当前），不移动游标。 */
    public func peek(offset: Int64): ?Rune {
        if (offset < 0 || offset > 8) {
            return None
        }
        if (!fillTo(offset + 1)) {
            return None
        }
        this.pending[this.head + offset]
    }

    /** 消费并返回当前字符。 */
    public func advance(): ?Rune {
        if (!fillTo(1)) {
            return None
        }
        let r = this.pending[this.head]
        this.head++
        if (r == r'\n') {
            this.line++
            this.column = 1
        } else {
            this.column++
        }
        this.compact()
        r
    }

    /** 下一个待读字符的 1-based 行列号。 */
    public func position(): SourcePosition {
        SourcePosition(this.line, this.column)
    }

    /** 当前字符是否已到流末尾。 */
    public func isEof(): Bool {
        this.peek(0).isNone()
    }
}

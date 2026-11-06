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
 * `skipElement()` 的标签级扫描器。
 *
 * 跳过期间**不解析属性值、不解码实体、不建节点**，只按深度配对：
 * 从当前元素内部开始，遇到开标签深度 +1、遇结束标签 -1，回到 0 即结束。
 *
 * 但必须正确处理四种会「假装成 `>`」的东西：引号内的 `>`、`<!-- -->`、
 * `<![CDATA[ ]]>`、`<? ?>`。缺一个，`<!-- a > b -->` 就能骗过扫描器。
 */
internal class SkipScanner {
    /** 消费到与 `startName` 匹配的结束标签之后（含）。 */
    static func skipSubtree(lexer: Lexer, startName: RawName): Unit {
        var depth: Int64 = 0
        while (true) {
            match (lexer.advance()) {
                case Some(r) =>
                    if (r != r'<') {
                        continue
                    }
                    match (lexer.peek(0)) {
                        case Some(next) =>
                            if (next == r'/') {
                                lexer.advance()
                                let name = lexer.readName()
                                lexer.skipWhitespace()
                                if (lexer.peek(0) != Some(r'>')) {
                                    throw lexer.error("跳过子树时结束标签缺少「>」")
                                }
                                lexer.advance()
                                if (depth == 0) {
                                    if (name.local != startName.local) {
                                        throw lexer.error("跳过子树时结束标签不匹配")
                                    }
                                    return
                                }
                                depth--
                            } else if (next == r'!') {
                                lexer.advance()
                                if (lexer.startsWith("--")) {
                                    skipUntil(lexer, "-->")
                                } else if (lexer.startsWith("[CDATA[")) {
                                    skipUntil(lexer, "]]>")
                                } else {
                                    throw lexer.error("跳过子树时遇到未知的「<!」构造")
                                }
                            } else if (next == r'?') {
                                lexer.advance()
                                skipUntil(lexer, "?>")
                            } else {
                                if (!scanStartTag(lexer)) {
                                    depth++
                                }
                            }
                        case None => throw lexer.error("提前 EOF：跳过子树时未找到匹配的结束标签")
                    }
                case None => throw lexer.error("提前 EOF：跳过子树时未找到匹配的结束标签")
            }
        }
    }

    /** 扫描一个开始标签，返回是否自闭合。 */
    private static func scanStartTag(lexer: Lexer): Bool {
        var lastWasSlash = false
        var quoteRune: ?Rune = None
        var result: ?Bool = None
        while (result.isNone()) {
            match (lexer.advance()) {
                case Some(r) =>
                    match (quoteRune) {
                        case Some(q) =>
                            lastWasSlash = false
                            if (r == q) {
                                quoteRune = None
                            }
                        case None =>
                            if (r == r'"' || r == r'\'') {
                                quoteRune = Some(r)
                                lastWasSlash = false
                            } else if (r == r'>') {
                                result = Some(lastWasSlash)
                            } else {
                                lastWasSlash = r == r'/'
                            }
                    }
                case None => throw lexer.error("提前 EOF：跳过子树时标签未闭合")
            }
        }
        result.getOrThrow()
    }

    private static func skipUntil(lexer: Lexer, terminator: String): Unit {
        while (true) {
            if (lexer.startsWith(terminator)) {
                lexer.consume(terminator)
                return
            }
            match (lexer.advance()) {
                case Some(_) => ()
                case None => throw lexer.error("提前 EOF：跳过子树时构造未闭合")
            }
        }
    }
}

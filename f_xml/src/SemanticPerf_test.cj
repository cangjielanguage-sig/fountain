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

import std.unittest.*
import std.unittest.testmacro.*
import std.time.MonoTime
import fountain::f_base.StringGenerator

/**
 * 分段计时（**诊断用，非门禁**）：Gate T 未达标时用来决定 `design.md` §8 走哪一级阶梯。
 *
 * 只打印，不做任何断言；`F_XML_PERF=1` 时才跑。
 */
@Test
public class SemanticPerf_test {
    private func lexerDoc(targetBytes: Int64): String {
        let gen = StringGenerator()
        gen.append<String>("<root>")
        var size: Int64 = 6 + 7
        var record: Int64 = 0
        while (true) {
            let one = "<item id=\"${record}\" a=\"v\">text-${record}</item>"
            let next = size + Int64(one.size)
            if (next > targetBytes) {
                break
            }
            gen.append<String>(one)
            size = next
            record++
        }
        gen.append<String>("</root>")
        gen.toString()
    }

    /** 纯字符层扫描：只调 `advanceFast`，不切 token。 */
    @TestCase
    public func charLayerScan(): Unit {
        if (!perfGateEnabled()) {
            println("semantic-perf: disabled (set F_XML_PERF=1)")
            return
        }
        let doc = this.lexerDoc(1024 * 1024)
        let window = LineWindow(Utf8RuneSource(TextInputStream(doc)))
        let start = MonoTime.now()
        var count: Int64 = 0
        while (window.advanceFast() >= 0) {
            count++
        }
        let elapsed = (MonoTime.now() - start) / Duration.millisecond
        println("semantic-perf: char_layer_cps=${count} ms=${elapsed} mb_s=${Float64(doc.size) / elapsed / 1024.0}")
    }

    /** 词法层：切完所有令牌（含名字驻留、批量扫描）。 */
    @TestCase
    public func lexerTokens(): Unit {
        if (!perfGateEnabled()) {
            println("semantic-perf: disabled (set F_XML_PERF=1)")
            return
        }
        let doc = this.lexerDoc(1024 * 1024)
        let lexer = makeLexer(doc)
        let start = MonoTime.now()
        var tokens: Int64 = 0
        while (true) {
            let token = lexer.nextToken(ParserState.Content)
            tokens++
            match (token) {
                case Token.TEof => break
                case _ => ()
            }
        }
        let elapsed = (MonoTime.now() - start) / Duration.millisecond
        println(
            "semantic-perf: tokens=${tokens} ms=${elapsed} mb_s=${Float64(doc.size) / elapsed / 1024.0} " +
            "names_hits=${lexer.names.hits} names_misses=${lexer.names.misses} peek_calls=${lexer.peekCalls}"
        )
    }

    /** 完整事件层（同 Gate 的口径），用来和上面两段相减看语义层净成本。 */
    @TestCase
    public func fullParse(): Unit {
        if (!perfGateEnabled()) {
            println("semantic-perf: disabled (set F_XML_PERF=1)")
            return
        }
        let result = runSyntheticPass(1024 * 1024, 8192)
        println("semantic-perf: full_parse ms=${result[0]} events=${result[1]}")
    }
}

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
package fountain::f_base

import std.unittest.*
import std.unittest.testmacro.*

/**
 * `StringGenerator` 此前没有专属用例（只有 51 个使用方间接覆盖），这里先补上
 * `append(Rune)`（bug-orm.md `ORM-N1` 的 P0 项）的等价性：新重载必须与旧路径
 * `append<String>(r.toString())` **逐字节一致**，覆盖 1–4 字节 UTF-8。
 */
@Test
public class StringGeneratorRune_test {
    private static let runes: Array<Rune> = [
        // SQL 拼接热字符（ASCII，走单字节快路径）
        r'?', r',', r'(', r')', r' ', r'\n', r'\t', r"'", r'"', r'0', r'Z',
        // 2 / 3 / 4 字节 UTF-8
        r'é', r'中', r'爱', r'😀', r'𐍈'
    ]

    @TestCase
    public func testAppendRuneMatchesStringPath(): Unit {
        let gen = StringGenerator()
        let expected = StringGenerator()
        for (r in runes) {
            gen.append(r)
            expected.append<String>(r.toString())
        }
        // 整段逐字节一致 + 长度一致
        @Assert(expected.toString(), gen.toString())
        @Assert(expected.size, gen.size)
        @Assert(true, expected.unsafeBytes() == gen.unsafeBytes())
    }

    @TestCase
    public func testAppendRuneGrowsSizeByUtf8Size(): Unit {
        let gen = StringGenerator()
        var want: Int64 = 0
        for (r in runes) {
            let before = gen.size
            gen.append(r)
            want += Rune.utf8Size(r)
            @Assert(Rune.utf8Size(r), gen.size - before)
        }
        @Assert(want, gen.size)
    }

    /** SQL 里最常出现的四个字符，字节序列要明确（钉住 ASCII 快路径） */
    @TestCase
    public func testHotAsciiRunesProduceExpectedBytes(): Unit {
        let gen = StringGenerator()
        gen.append(r'(').append(r'?').append(r',').append(r'?').append(r')')
        let want: Array<Byte> = [b'(', b'?', b',', b'?', b')']
        @Assert(true, want == gen.unsafeBytes())
        @Assert('(?,?)', gen.toString())
    }
}

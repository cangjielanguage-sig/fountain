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

@Test
public class CharsetRuneSource_test {
    /** GBK 文档逐字符读出。 */
    @TestCase
    public func gbkCharacters(): Unit {
        let source = CharsetRuneSource(
            MemoryInputStream(gbkBytes("<a>中文测试</a>")),
            charset: Charsets.GBK,
            bufSize: 8
        )
        @Assert(drainRunes(source) == "<a>中文测试</a>")
    }

    /** `bufSize` 变化不改变结果。 */
    @TestCase
    public func bufSizeInvariant(): Unit {
        let text = "<a>${repeatText("中文", 40)}</a>"
        let small = CharsetRuneSource(MemoryInputStream(gbkBytes(text)), charset: Charsets.GBK, bufSize: 8)
        let large = CharsetRuneSource(MemoryInputStream(gbkBytes(text)), charset: Charsets.GBK, bufSize: 4096)
        @Assert(drainRunes(small) == text)
        @Assert(drainRunes(large) == text)
    }

    /** 初始位置为 (1, 1)。 */
    @TestCase
    public func initialPosition(): Unit {
        let source = CharsetRuneSource(MemoryInputStream(gbkBytes("中")), charset: Charsets.GBK)
        @Assert(source.position().line == 1 && source.position().column == 1)
    }
}

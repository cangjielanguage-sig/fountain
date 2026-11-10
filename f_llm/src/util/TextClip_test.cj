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
package fountain::f_llm.util

import std.unittest.*
import std.unittest.testmacro.*

@Test
class TextClip_test {
    @TestCase
    func testShortTextUnchanged(): Unit {
        @Expect(TextClip.clip('短文本', 10), '短文本')
    }

    @TestCase
    func testExactLimitKeepsAll(): Unit {
        @Expect(TextClip.clip('0123456789', 10), '0123456789')
    }

    @TestCase
    func testOverLimitAppendsEllipsis(): Unit {
        @Expect(TextClip.clip('0123456789', 4), '0123…')
    }

    @TestCase
    func testChineseCountedByChars(): Unit {
        let text = '中文内容'  // 4 个字符、12 字节
        @Expect(TextClip.clip(text, 4), text)
        @Expect(TextClip.clip(text, 2), '中文…')
    }

    @TestCase
    func testEmptyAndNonPositive(): Unit {
        @Expect(TextClip.clip('', 10), '')
        @Expect(TextClip.clip('abc', 0), '')
    }
}

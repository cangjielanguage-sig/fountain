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
package fountain::f_util

import std.collection.HashMap
import std.unittest.*
import std.unittest.testmacro.*

/**
 * `TextTemplate.compile` 的缓存键必须包含 `prefix` / `suffix`：
 * 同一个模板串在两种分隔符下编译时不得串味。
 *
 * 每个用例使用独占的模板串，避免静态缓存跨用例互相影响。
 */
@Test
public class TextTemplateCacheKey_test {
    @TestCase
    func braceFirstThenDefault(): Unit {
        // f_log 形态：`{alpha}` 是占位符，`$` 是字面量。
        let tpl: String = #"hello ${alpha}"#
        let brace = TextTemplate.compile(tpl, prefix: "{", suffix: "}")
        let map = HashMap<String, String>()
        map["alpha"] = "world"
        @Expect(brace.format<String>(map), "hello $world")

        // 默认形态：`${alpha}` 是占位符。
        let plain = TextTemplate.compile(tpl, prefix: #"${"#, suffix: "}")
        @Expect(plain.format<String>(map), "hello world")
    }

    @TestCase
    func defaultFirstThenBrace(): Unit {
        // 默认形态下 `{beta}` 是字面量，原样输出。
        let tpl: String = #"hello {beta}"#
        let plain = TextTemplate.compile(tpl, prefix: #"${"#, suffix: "}")
        let map = HashMap<String, String>()
        map["beta"] = "world"
        @Expect(plain.format<String>(map), "hello {beta}")

        // f_log 形态下 `{beta}` 是占位符。
        let brace = TextTemplate.compile(tpl, prefix: "{", suffix: "}")
        @Expect(brace.format<String>(map), "hello world")
    }

    @TestCase
    func sameDelimiterRepeated(): Unit {
        let tpl: String = #"hello ${repeat}${repeat}"#
        let map = HashMap<String, String>()
        map["repeat"] = "x"
        let first = TextTemplate.compile(tpl, prefix: "{", suffix: "}")
        let second = TextTemplate.compile(tpl, prefix: "{", suffix: "}")
        @Expect(first.format<String>(map), "hello $x$x")
        @Expect(second.format<String>(map), "hello $x$x")
    }

    @TestCase
    func defaultDelimiterUnchanged(): Unit {
        let tpl: String = #"hi ${delta}"#
        let map = HashMap<String, String>()
        map["delta"] = "world"
        @Expect(TextTemplate.compile(tpl, prefix: #"${"#, suffix: "}").format<String>(map), "hi world")
    }

    @TestCase
    func placeholderOverload(): Unit {
        let tpl: String = "hi #epsilon#"
        let map = HashMap<String, String>()
        map["epsilon"] = "world"
        @Expect(TextTemplate.compile(tpl, placeholder: "#").format<String>(map), "hi world")
    }
}

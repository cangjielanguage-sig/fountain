/*
Copyright (c) 2025 WuJingrun（吴京润）

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
package fountain::f_data.json

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.base.*

/**
 * 覆盖 2026-10-15 修复的 JSON 序列化问题（详见 doc/REVIEW_2026-10-15.md）：
 * DataJson 的 ToJsonString 路径此前不转义，含引号/反斜杠/换行的字符串会生成非法 JSON。
 *
 * 注意：本包不能 import `fountain::f_data.macros`（会形成
 * f_data -> f_data.json -> f_data.macros -> f_data 循环依赖），
 * 因此依赖 `@DataAssist` 的 schema 测试放在 `f_data.test` 包（JsonSchema_test.cj）。
 */
@Test
public class DataJsonEscapeTest {
    @TestCase
    public func testDataStringEscaping(): Unit {
        // 修复前输出 `"a"b"`（非法 JSON）
        @Assert('"a\\\"b"', DataString('a"b').toJsonString())
        @Assert('"a\\\\b"', DataString('a\\b').toJsonString())
        @Assert('"a\\nb"', DataString('a\nb').toJsonString())
        @Assert('"plain"', DataString('plain').toJsonString())
    }
}

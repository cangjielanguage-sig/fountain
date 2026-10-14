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
package fountain::f_data.validation

import std.unittest.*
import std.unittest.testmacro.*

/**
 * 覆盖 2026-10-15 修复的校验器缺陷（详见 doc/REVIEW_2026-10-15.md）：
 * StringSize.min 未生效、IsDuration 与解析器脱节、IsIntegers/国家码分隔符未转义。
 */
@Test
public class ValidatorTest {
    @TestCase
    public func testStringSizeMin(): Unit {
        let v = StringSize(min: 6, max: 50)
        @Assert(false, v.validate('abc'))
        @Assert(true, v.validate('abcdef'))
        // 修复前 min 从未参与判定（`v.size >= 0` 恒真），空串也会通过
        @Assert(false, v.validate(''))
    }

    @TestCase
    public func testIsDurationAlignedWithParser(): Unit {
        let v = IsDuration()
        @Assert(true, v.validate('1d1h1m1s'))
        @Assert(true, v.validate('-45s'))
        @Assert(true, v.validate('1d1h1m1s1ms1us1ns'))
        // 修复前用 f_regex 的 DURATION 正则会放行这些串，解析阶段才失败
        @Assert(false, v.validate('1s1s'))
        @Assert(false, v.validate('9h10d'))
        @Assert(false, v.validate('1m 2s'))
        @Assert(false, v.validate('5'))
    }

    @TestCase
    public func testIsIntegersSeparatorIsLiteral(): Unit {
        let v = IsIntegers(separator: '.')
        @Assert(true, v.validate('1.2.3'))
        // 修复前 '.' 被当作「任意字符」，`1a2b3` 也能通过
        @Assert(false, v.validate('1a2b3'))
    }

    @TestCase
    public func testChineseCellPhoneCountryCodeIsLiteral(): Unit {
        let v = IsChineseCellPhone(withCountryCode: true)
        // 修复前 '(86)' 被当作捕获组：能匹配 "8613..." 却匹配不了 "(86)13..."
        @Assert(true, v.validate('(86)13800138000'))
        @Assert(false, v.validate('8613800138000'))
    }
}

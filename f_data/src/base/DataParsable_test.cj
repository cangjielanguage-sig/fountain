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
package fountain::f_data.base

import std.unittest.*
import std.unittest.testmacro.*

/**
 * `Duration.tryParse` 的解析约定：
 * 单位链 `d/h/m/s/ms/us/ns`；数字段可带正负号、可多段拼接（`1d2h`）；
 * **不能解析、或数值超出 `Duration` 表示范围时返回 `None`**（调用方据此回退默认值），不抛异常。
 * `Duration.parse` 直接由内部 `doTryParse` 经 `getOrThrow()` 取值：
 * 不能解析（含数字段超出 `Int64`）时抛 `NoneValueException`，数值溢出时抛 `ArithmeticException`。
 */
@Test
public class DataParsableTest {
    //用 match 取结果再断言：不在断言里比较 Option<Duration>
    //（直接比较会引入本模块的泛型实例化，实测会触发链接期泛型符号缺失）
    private func expect(s: String, expected: Duration): Unit {
        match (Duration.tryParse(s)) {
            case Some(d) => @Assert(expected, d)
            case None => @Assert('Some(${expected})', 'None')
        }
    }
    private func expectNone(s: String): Unit {
        @Assert(true, Duration.tryParse(s).isNone())
    }

    @TestCase
    public func testSingleUnit(): Unit {
        expect('45s', Duration.second * 45)
        expect('30s', Duration.second * 30)
        expect('1m', Duration.minute)
        expect('2h', Duration.hour * 2)
        expect('3d', Duration.day * 3)
        expect('150ms', Duration.millisecond * 150)
        expect('500us', Duration.microsecond * 500)
        expect('700ns', Duration.nanosecond * 700)
        //≤0（如 0s）是合法值：调用方按「真无限等待」解释
        expect('0s', Duration.Zero)
        expect('-45s', Duration.second * -45)
    }

    @TestCase
    public func testMultiSegment(): Unit {
        expect('1d2h', Duration.day + Duration.hour * 2)
        expect('1h30m', Duration.hour + Duration.minute * 30)
    }

    @TestCase
    public func testSignedSegments(): Unit {
        // 符号只属于紧随的数字段，两种解析入口都按各段的值相加。
        for ((s, expected) in [
            ('1m-2s', Duration.second * 58),
            ('-1m2s', Duration.second * -58),
            ('-1m-2s', Duration.second * -62),
            ('1s-1000ms', Duration.Zero)
        ]) {
            expect(s, expected)
            @Assert(expected, Duration.parse(s))
        }
        for (s in ['1m-', '1m--2s', '1m-2']) {
            expectNone(s)
            // 不能解析 ⇒ parse 落在 doTryParse(s).getOrThrow() 的 None 分支
            var rejected = false
            try {
                Duration.parse(s)
            } catch (_: NoneValueException) {
                rejected = true
            }
            @Assert(rejected)
        }
    }

    @TestCase
    public func testExplicitPlusSign(): Unit {
        expect('+5s', Duration.second * 5)
        expect('1m+2s', Duration.second * 62)
        expect('+1s-500ms', Duration.millisecond * 500)
        for (s in ['+', '1s+', '++1s', '+-1s', '-+1s', '--1s']) {
            expectNone(s)
        }
    }

    @TestCase
    public func testDurationLimits(): Unit {
        expect('9223372036854775807s', Duration.second * Int64.Max)
        expect('-9223372036854775808s', Duration.second * Int64.Min)
        expect('9223372036854775807s999999999ns', Duration.Max)
    }

    @TestCase
    public func testDigitBeyondInt64ReturnsNone(): Unit {
        // 数字段本身超出 Int64 ⇒ Int64.tryParse 返回 None，属「不能解析」；
        // 与 Int64.tryParse 对超长值的行为一致：返回 None 而不是抛异常。
        for (s in ['9223372036854775808s', '-9223372036854775809s']) {
            expectNone(s)
            var rejected = false
            try {
                Duration.parse(s)
            } catch (_: NoneValueException) {
                rejected = true
            }
            @Assert(rejected)
        }
    }

    @TestCase
    public func testOverflowThrows(): Unit {
        // 数值超出 Duration 表示范围：tryParse 返回 None（与 Int64.tryParse 对超长值的行为一致）；
        // parse 不包装异常，直接抛出 doTryParse 的溢出异常。
        for (s in [
            '9223372036854775807h', '9223372036854775807s1s',
            '-9223372036854775808s-1ns', '9223372036854775807s999999999ns1ns'
        ]) {
            expectNone(s)
            var thrown = false
            try {
                Duration.parse(s)
            } catch (_: ArithmeticException) {
                thrown = true
            }
            @Assert(thrown)
        }
    }

    @TestCase
    public func testInvalidReturnsNone(): Unit {
        //非法输入必须返回 None，而不是抛异常
        expectNone('abc')
        expectNone('')
        expectNone('45')//只有数字没给单位
        expectNone('s')//只有单位没有数字
        expectNone('45x')
        expectNone('1m2')
    }
}

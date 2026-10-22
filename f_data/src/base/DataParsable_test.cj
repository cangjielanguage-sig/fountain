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
 * 单位链 `d/h/m/s/ms/us/ns`，片段连写（`1d2h`），字符串中不允许空白；
 * 整个字符串可带一个正负号前缀（`-45s`、`-1m`、`-10d`、`+3s`），作用于整个值，
 * 且符号只允许出现在字符串开头——`1m-2s`、`1m+2s`、`-1m 2s` 这类段间符号按四则运算拒绝；
 * `-5`、`+3` 这类没有单位的串也不是合法的 Duration 字符串。
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
    }

    @TestCase
    public func testMultiSegment(): Unit {
        expect('1d2h', Duration.day + Duration.hour * 2)
        expect('1h30m', Duration.hour + Duration.minute * 30)
    }

    @TestCase
    public func testFullUnitChain(): Unit {
        let expected = (Duration.day * 10 + Duration.hour * 3 + Duration.minute * 2 +
            Duration.second * 6 + Duration.millisecond * 5 + Duration.microsecond * 4 +
            Duration.nanosecond * 7)
        expect('10d3h2m6s5ms4us7ns', expected)
        //开头的负号作用于整个值
        expect('-10d3h2m6s5ms4us7ns', Duration.Zero - expected)
        //带空白的写法不合法
        expectNone('10d 3h 2m 6s 5ms 4us 7ns')
    }

    @TestCase
    public func testUnitOrderRejected(): Unit {
        // 单位必须从左往右严格变小且至多出现一次：d > h > m > s > ms > us > ns
        for (s in [
            '9h10d', '9m5d', '9h5m3d', '5m9h3d',
            '1ms1s', '1m1h', '1d1d', '1s1s',
            '9223372036854775807s1s', '-9223372036854775807s1s'
        ]) {
            expectNone(s)
            var rejected = false
            try {
                Duration.parse(s)
            } catch (_: NoneValueException) {
                rejected = true
            }
            @Assert(rejected)
        }
        // 严格递减的完整单位链合法
        expect('1d1h1m1s1ms1us1ns', (Duration.day + Duration.hour + Duration.minute +
            Duration.second + Duration.millisecond + Duration.microsecond + Duration.nanosecond))
    }

    @TestCase
    public func testToStringRoundTrip(): Unit {
        // 解析格式与 Duration.toString() 的输出一致：toString 的结果必须能读回原值。
        // 含两个极值：Max 秒 / Min 秒（后者要求解析时用「加负值」而不是减法，
        // 否则 Duration 的减法会在 Min 秒边界误报溢出）
        let full = Duration.day + Duration.hour + Duration.minute + Duration.second +
            Duration.millisecond + Duration.microsecond + Duration.nanosecond
        for (d in [
            Duration.Zero, Duration.second * 45, Duration.hour,
            Duration.day + Duration.hour * 2, Duration.minute * -1,
            Duration.Zero - (Duration.minute + Duration.second * 2),
            Duration.Max, Duration.second * Int64.Max, Duration.second * Int64.Min,
            Duration.nanosecond * -1,
            full, full * -1, Duration.millisecond * 1000, Duration.second * 90
        ]) {
            match (Duration.tryParse(d.toString())) {
                case Some(v) => @Assert(d, v)
                case None => @Assert('Some(${d})', 'None')
            }
        }
    }

    @TestCase
    public func testLeadingSign(): Unit {
        // 字符串开头的正负号作用于整个值
        for ((s, expected) in [
            ('-45s', Duration.second * -45),
            ('+5s', Duration.second * 5),
            ('-1m', Duration.minute * -1),
            ('-10d', Duration.day * -10),
            ('+3s', Duration.second * 3),
            ('-1m2s', Duration.second * -62),
            ('+1m2s', Duration.second * 62)
        ]) {
            expect(s, expected)
            @Assert(expected, Duration.parse(s))
        }
    }

    @TestCase
    public func testSignsAndBlanksRejected(): Unit {
        // 段与段之间的 + / - 是四则运算；字符串中也不允许空白
        for (s in [
            '1m-2s', '1m+2s', '1s-1000ms', '-1m-2s', '+1s-500ms',
            '1m -2s', '1m +2s', '-1m -2s', '-1m -10d +3s', '-1m - 10d + 3s',
            '-1m 2s', '1d 2h', '1h 30m',
            '1m-', '1m--2s', '1m-2'
        ]) {
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
    public func testInvalidSigns(): Unit {
        for (s in ['+', '1s+', '++1s', '+-1s', '-+1s', '--1s', '1s +', '+ 5s']) {
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
            '9223372036854775807h', '-9223372036854775808d',
            '9223372036854775807s999999999ms'
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
        expectNone(' ')
        expectNone('45')//只有数字没给单位
        expectNone('-5')//没有单位的纯数字（即使带符号）
        expectNone('+3')
        expectNone('s')//只有单位没有数字
        expectNone('45x')
        expectNone('1m2')
    }
}

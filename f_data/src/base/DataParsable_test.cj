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
 * `Duration.tryParse` 的约定（对应 `bug-cross.md` 的 `X-2`）：
 * 单位链 `d/h/m/s/ms/us/ns`；数字段可带负号、可多段拼接（`1d2h`）；
 * **非法输入返回 `None`**（调用方据此回退默认值），不抛异常。
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

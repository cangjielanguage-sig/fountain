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
package fountain::f_mvc

import std.unittest.*
import std.unittest.testmacro.*

/**
 * §1.12 / `MVC-2`：访问日志关闭时不得序列化参数与返回值。
 *
 * 测的是包内接缝 `lazyAccessLogFields`（`accessLog` 里唯一的参数/返回值序列化点）：
 * 构造它返回的闭包不得触碰任何参数，调用闭包才做序列化；`accessLog.logContent` 只在
 * 真正要写日志时才调用它。
 * `HttpContext` / `HttpRequest` 是 stdx 的类、测试里造不出来，所以用「计数 spy + 假参数」
 * 直接驱动接缝；`accessLog` 里其余的 `request.xxx` 读取只是字符串拼接。
 */

/** 计数 spy：只实现 ToString，命中 anyToString 的 `case x: ToString` 分支，每被序列化一次 +1 */
class AccessLogCountingToString <: ToString {
    private let counter: Box<Int64>
    AccessLogCountingToString(counter: Box<Int64>) {
        this.counter = counter
    }
    public func toString(): String {
        counter.value++
        return 'counted'
    }
}

@Test
class RequestMeta_test {
    /** 惰性：建闭包不序列化；调用闭包时参数、返回值各一次，文本与原来一致 */
    @TestCase
    public func testFieldsAreLazy(): Unit {
        let counter = Box<Int64>(0)
        let spy = AccessLogCountingToString(counter)
        let args = ArrayList<Any>()
        args.add(spy)
        let returned: ?Any = spy
        let fields = lazyAccessLogFields(args, returned)
        @Assert(0, counter.value)          // 还没取文本 ⇒ 一次序列化都不该有（修前形态：这里已经是 1）
        let (params, result) = fields()
        @Assert(2, counter.value)          // 参数 + 返回值各一次
        @Assert('[counted]', params)
        @Assert('counted', result)
    }

    /** 返回值是 None：文本为 'None'，且只序列化参数 */
    @TestCase
    public func testNoneResult(): Unit {
        let counter = Box<Int64>(0)
        let spy = AccessLogCountingToString(counter)
        let args = ArrayList<Any>()
        args.add(spy)
        args.add(spy)
        let (params, result) = lazyAccessLogFields(args, None<Any>)()
        @Assert(2, counter.value)
        @Assert('[counted,counted]', params)
        @Assert('None', result)
    }
}

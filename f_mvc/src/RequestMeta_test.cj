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

/** 计数 + 可控抛错的 `Resource`，用于 §2.5 / `MVC-C2` 的关闭语义用例 */
class CountingResource <: Resource {
    private let closes: Box<Int64>
    private let closeFails: Bool
    CountingResource(closes: Box<Int64>, closeFails!: Bool) {
        this.closes = closes
        this.closeFails = closeFails
    }
    public func isClosed(): Bool {
        false
    }
    public func close(): Unit {
        closes.value++
        if (closeFails) {
            throw Exception('close boom')
        }
    }
}

/**
 * §2.5 / `MVC-C2`：`respond<R>`（`R <: ToData`）的分支决策与 `Resource` 关闭。
 * `HttpContext` 造不出来，故直接驱动两个包内接缝 `respondKind` / `closeResultIfResource`。
 */
@Test
class RequestMeta_respond_test {
    /** 非空结果 + 缺 Accept ⇒ 渲染（缺 Accept 按星号通配处理），而不是 406（修前形态：NotAcceptable） */
    @TestCase
    public func testNoAcceptRendersBody(): Unit {
        @Assert('Render', respondKind(false, None).toString())
    }

    /** 非空结果 + 有 Accept ⇒ 渲染 */
    @TestCase
    public func testAcceptRendersBody(): Unit {
        @Assert('Render', respondKind(false, Some('application/json')).toString())
    }

    /** 空结果三分支不变：无 Accept ⇒ 不带 Content-Type 的空体；Accept 含星号通配 ⇒ 带 Content-Type 的空体；其余 406 */
    @TestCase
    public func testEmptyResultBranches(): Unit {
        @Assert('EmptyWithoutContentType', respondKind(true, None).toString())
        @Assert('EmptyWithContentType', respondKind(true, Some('*/*')).toString())
        @Assert('NotAcceptable', respondKind(true, Some('application/json')).toString())
    }

    /** `Resource` 结果被关闭（恰好一次） */
    @TestCase
    public func testResourceIsClosed(): Unit {
        let closes = Box<Int64>(0)
        let res = CountingResource(closes, closeFails: false)
        @Assert(true, closeResultIfResource(res).isNone())
        @Assert(1, closes.value)
    }

    /** 关闭失败：回传异常而不抛（由调用方记录日志） */
    @TestCase
    public func testCloseFailureIsReturnedNotThrown(): Unit {
        let res = CountingResource(Box<Int64>(0), closeFails: true)
        let e = closeResultIfResource(res)
        @Assert(true, e.isSome())
        @Assert('close boom', e.getOrThrow().message)
    }

    /** 非 `Resource` 结果：无动作、不抛 */
    @TestCase
    public func testNonResourceIsUntouched(): Unit {
        @Assert(true, closeResultIfResource(42).isNone())
    }
}

/**
 * §2.6 / `MVC-8`：请求级 ThreadLocal 必须随请求结束清掉，否则会串到同线程的下一个请求
 * （如前一个 401，本请求 200 也记 401）。
 */
@Test
class RequestMeta_locals_test {
    /** status：clear 之后必须回落到默认 200（修前形态：clear 为空实现 ⇒ 仍读到上一个请求的 401） */
    @TestCase
    public func testResponseStatusIsCleared(): Unit {
        RequestMeta.setResponseStatus(HttpStatus.UNAUTHORIZED)
        @Assert(HttpStatus.UNAUTHORIZED.value, RequestMeta.getResponseStatus())
        RequestMeta.clearResponseStatus()
        @Assert(HttpStatus.OK.value, RequestMeta.getResponseStatus())
    }
}

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
 * §2.2 / `MVC-C3`：`@RequestBody` 遇到缺失 / 空 / 未注册的 Content-Type 时必须以 415 快速失败，
 * 而不是 getOrThrow 抛 NoneValueException（⇒ 500）。
 *
 * 测的是包内接缝 `requestBodyMediaType`（`RequestBody.extract` 里唯一的 Content-Type 解析点）：
 * 这些情况下它应 perform `MVCBreakingCommand(415)`，由请求链上 `RequestMeta.setHandle` 里既有的
 * handle 分支回 415；用例自己装一个 handle 接住它（`HttpContext` 造不出来，绕开它直接驱动接缝）。
 */
@Test
class ControllerFuncParam_test {
    /** 接缝以 415 快速失败时返回该状态；修前形态（抛异常 / 返回 None）统一回退成 OK 当哨兵 */
    private func breakStatus(contentType: ?String): HttpStatus {
        let status = Box<Option<HttpStatus>>(None<HttpStatus>)   // handle 分支不能捕获 var，用 Box 兜
        try {
            requestBodyMediaType(contentType)
        } handle (cmd: MVCBreakingCommand) {
            status.value = Some(cmd.status)
        } catch (_: Exception) {
            // 修前形态：getOrThrow 的 NoneValueException / parse 的 MediaTypeException（上层会变成 500）
        }
        status.value ?? HttpStatus.OK
    }

    /** 缺 Content-Type ⇒ 415（修前：NoneValueException ⇒ 500） */
    @TestCase
    public func testMissingContentTypeIs415(): Unit {
        @Assert(HttpStatus.UNSUPPORTED_MEDIA_TYPE.value, breakStatus(None).value)
    }

    /** 空串 Content-Type ⇒ 415 */
    @TestCase
    public func testEmptyContentTypeIs415(): Unit {
        @Assert(HttpStatus.UNSUPPORTED_MEDIA_TYPE.value, breakStatus(Some('')).value)
    }

    /** 未注册的媒体类型（路由层会放行、`MediaTypes` 里没有）⇒ 415，而不是 MediaTypeException ⇒ 500 */
    @TestCase
    public func testUnregisteredContentTypeIs415(): Unit {
        @Assert(HttpStatus.UNSUPPORTED_MEDIA_TYPE.value, breakStatus(Some('application/xml')).value)
    }

    /** 已注册的类型仍按原路解析（回归保护） */
    @TestCase
    public func testJsonContentTypeParsed(): Unit {
        @Assert('application/json', requestBodyMediaType(Some('application/json')).mediaType)
    }
}

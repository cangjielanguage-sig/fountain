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
 * §3.1 / `MVC-L5`：未命中路由（静态资源 / 404）不再每请求构造 `RequestMeta`
 * （后者会连带分配 2 个 `HashSet`、`RequestArgMeta`（内含 `HashMap`）与闭包），
 * 改由轻量 handler `StaticResourceOrNotFoundHandler` 承担（只持 `path`）。
 *
 * 说明：该 handler 的行为需要 `HttpContext`，无法在 f_mvc 测试里驱动，
 * 故本用例钉的是**结构契约**（分发结果的类型），行为侧证据为「逻辑逐字搬运 + 其余用例全绿」。
 */
@Test
class HttpRequestDistributorImpl_test {
    /** 未注册路径分发到轻量 handler（修前返回的是每请求构造的 `RequestMeta`） */
    @TestCase
    public func testUnmatchedPathReturnsLightweightHandler(): Unit {
        let handler = HttpRequestDistributorImpl.instance.distribute('/__mvc_l5_unregistered_path__')
        @Assert(true, handler is StaticResourceOrNotFoundHandler)
    }
}

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
 * §3.1 / `MVC-L1`：OPTIONS 的 `Allow` 串（`"OPTIONS, GET, POST, …"`，
 * 经 `MultiRequestMethodHandler` 写入 `Allow` / `Access-Control-Allow-Method` 响应头）。
 * 两条不变量：①首项 OPTIONS、其余为已注册方法；②构建一次后不再随 `metas` 重建。
 */
@Test
class MultiRequestMethodHandler_test {
    private static func registeredMetas(): HashMap<RequestMethod, HashMap<String, RequestMeta>> {
        let metas = HashMap<RequestMethod, HashMap<String, RequestMeta>>()
        metas[RequestMethod.GET] = HashMap<String, RequestMeta>()
        metas[RequestMethod.POST] = HashMap<String, RequestMeta>()
        metas[RequestMethod.WS] = HashMap<String, RequestMeta>()
        metas
    }

    /** 首项固定 OPTIONS，其余为已注册方法（顺序不保证 ⇒ 按集合断言） */
    @TestCase
    public func testAllowsContent(): Unit {
        let parts = allowsOf(registeredMetas()).split(", ")
        @Assert('OPTIONS', parts[0])
        let methods = HashSet<String>(parts)
        @Assert(4, methods.size)
        for (m in [RequestMethod.OPTIONS, RequestMethod.GET, RequestMethod.POST, RequestMethod.WS]) {
            @Assert(true, methods.contains(m.toString()))
        }
    }

    /**
     * 构建一次后不再随 `metas` 变化：注册期结束后 `metas` 不变，故可缓存。
     * 修前形态（每次 `get()` 重建）会因新增 PUT 而返回不同串 ⇒ 本用例失败。
     */
    @TestCase
    public func testAllowsIsBuiltOnce(): Unit {
        let metas = registeredMetas()
        let cache = AllowsCache(metas)
        let first = cache.get()
        metas[RequestMethod.PUT] = HashMap<String, RequestMeta>()
        @Assert(first, cache.get())
    }

    /**
     * §3.2 / `MVC-13`：WS 握手识别 —— `Upgrade: websocket`（忽略大小写）为真，其它/缺失为假。
     * 修前形态（接缝一律返回 `false`）：前两条断言失败。
     */
    @TestCase
    public func testIsWebSocketUpgrade(): Unit {
        func withUpgrade(value: String): HttpHeaders {
            let h = HttpHeaders()
            h.set('Upgrade', value)
            h
        }
        @Assert(true, isWebSocketUpgrade(withUpgrade('websocket')))
        @Assert(true, isWebSocketUpgrade(withUpgrade('WebSocket')))
        @Assert(false, isWebSocketUpgrade(withUpgrade('h2c')))
        @Assert(false, isWebSocketUpgrade(HttpHeaders()))
    }
}

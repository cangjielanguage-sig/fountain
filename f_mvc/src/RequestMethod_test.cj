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
 * §2.20 / `MVC-7`：`RequestMethod.hashCode()` 在路由热路径上每请求被调用 1–2 次
 * （`MultiRequestMethodHandler.cj:87,109` 的 `metas.get(...)`），修前实现是 `toString().hashCode()`
 * —— `toString()` 虽返回字面量，但每次都要重算一遍短串哈希。修后改为固定常量（声明序）。
 */
@Test
class RequestMethod_test {
    /** 8 个方法的哈希两两不同（HashMap 键的基本契约） */
    @TestCase
    public func testHashCodeIsDistinct(): Unit {
        let methods = [
            RequestMethod.GET, RequestMethod.POST, RequestMethod.PUT, RequestMethod.DELETE,
            RequestMethod.PATCH, RequestMethod.OPTIONS, RequestMethod.HEAD, RequestMethod.WS
        ]
        let seen = HashSet<Int64>()
        for (m in methods) {
            @Assert(true, seen.add(m.hashCode()))
        }
    }

    /**
     * 哈希随声明顺序递增：修后是常量表（GET < POST < PUT < DELETE < PATCH < OPTIONS < HEAD < WS），
     * 修前走 `toString().hashCode()` ⇒ 与声明顺序无关，本用例用于把「不再依赖字符串哈希」钉住。
     */
    @TestCase
    public func testHashCodeFollowsDeclarationOrder(): Unit {
        @Assert(true, RequestMethod.GET.hashCode() < RequestMethod.POST.hashCode())
        @Assert(true, RequestMethod.POST.hashCode() < RequestMethod.PUT.hashCode())
        @Assert(true, RequestMethod.PUT.hashCode() < RequestMethod.DELETE.hashCode())
        @Assert(true, RequestMethod.DELETE.hashCode() < RequestMethod.PATCH.hashCode())
        @Assert(true, RequestMethod.PATCH.hashCode() < RequestMethod.OPTIONS.hashCode())
        @Assert(true, RequestMethod.OPTIONS.hashCode() < RequestMethod.HEAD.hashCode())
        @Assert(true, RequestMethod.HEAD.hashCode() < RequestMethod.WS.hashCode())
    }
}

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

    /**
     * §3.2 / `MVC-L12`：`operator ==` 缺 `WS` 分支 ⇒ `(WS, WS)` 落到 `case _ => false`，
     * 违反 `Equatable` 的自反性（`!=` 由 `==` 派生 ⇒ `WS != WS` 为 true）。修前本用例失败。
     */
    @TestCase
    public func testWsIsEqualToItself(): Unit {
        @Assert(true, RequestMethod.WS == RequestMethod.WS)
        @Assert(false, RequestMethod.WS != RequestMethod.WS)
        // 路由侧的真实形态：parse 出来的方法与常量比较
        @Assert(true, RequestMethod.parse('WS') == RequestMethod.WS)
    }

    /**
     * §3.2 / `MVC-L12`：`RequestMethod.WS` 作为哈希容器键必须可命中。
     * std 的匹配是 `hash == 记录.hash && key == 记录.key`（无引用短路，
     * `cangjie_runtime/std/libs/std/collection/hash_map.cj:485`），而 `WS` 正是 WS 端点的注册键
     * （`HttpRequestDistributorImpl.cj:36`）⇒ `==` 不自反会让该键查不到。修前本用例失败。
     */
    @TestCase
    public func testWsIsUsableAsHashContainerKey(): Unit {
        let map = HashMap<RequestMethod, Int64>()
        map[RequestMethod.WS] = 1
        @Assert(Some(1), map.get(RequestMethod.WS))
        let set = HashSet<RequestMethod>()
        set.add(RequestMethod.WS)
        @Assert(true, set.contains(RequestMethod.WS))
    }
}

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
package fountain::f_rule.fact

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_rule.exception.*

/**
 * `FactSpaceRegistry` 的规则集级契约（`doc/02-fact-model.md` §6.8、§8）。
 *
 * 冻结是**级联**的：注册表冻结后，所有空间同时只读，运行期声明新空间抛 `NETWORK_FROZEN`。
 */
@Test
class FactSpaceRegistry_test {
    private func codeOf(action: () -> Unit): RuleErrorCode {
        var caught = RuleErrorCode.CLOSED
        try {
            action()
        } catch (e: RuleException) {
            caught = e.code
        }
        caught
    }

    /** 注册表按 id 声明空间；重复声明返回同一实例。 */
    @TestCase
    public func registryDeclaresSpaces(): Unit {
        let registry = FactSpaceRegistry()
        let orders = registry.declare("orders")
        let again = registry.declare("orders")

        @Expect(refEq(orders, again), true)
        @Assert(registry.ids(), ["orders"])
        @Expect(registry.has("orders"), true)
        @Expect(registry.get("users").isNone(), true)
    }

    /** 注册表冻结会级联冻结所有空间，之后声明新空间抛 `NETWORK_FROZEN`。 */
    @TestCase
    public func registryFreezeCascades(): Unit {
        let registry = FactSpaceRegistry()
        let orders = registry.declare("orders")
        registry.freeze()

        @Expect(registry.frozen, true)
        @Expect(orders.frozen, true)
        @Expect(codeOf({ => registry.declare("users") }), RuleErrorCode.NETWORK_FROZEN)
    }
}

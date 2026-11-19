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
package fountain::f_probe

import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.JsonObject

@Test
public class ProbeRegistry_test {
    /** 正常注册后可按 kind 枚举与查找。 */
    @TestCase
    public func registerAndLookup(): Unit {
        ProbeRegistry.clear()
        ProbeRegistry.registerAgent("k8s", {=> RegistryProbeAgent("k8s")})

        @Assert(ProbeRegistry.agents().size, 1)
        @Assert(ProbeRegistry.agents()[0], "k8s")
        let factory = ProbeRegistry.agent("k8s")
        @Assert(factory.isSome())
        @Assert(factory.getOrThrow()().kind, "k8s")

        ProbeRegistry.clear()
    }

    /** 重名注册被拒绝，且注册表仍指向第一次登记的工厂。 */
    @TestCase
    public func duplicateKindIsRejected(): Unit {
        ProbeRegistry.clear()
        ProbeRegistry.registerAgent("dup", {=> RegistryProbeAgent("first")})

        var caught = false
        try {
            ProbeRegistry.registerAgent("dup", {=> RegistryProbeAgent("second")})
        } catch (e: ProbeException) {
            caught = true
            @Assert(e.code, ProbeErrorCode.DUPLICATE)
            @Assert(e.message.contains("dup"))
        }
        @Assert(caught)
        @Assert(ProbeRegistry.agent("dup").getOrThrow()().kind, "first")

        ProbeRegistry.clear()
    }

    /** 多线程并发注册不同 kind，全部成功且数量一致。 */
    @TestCase
    public func concurrentRegistration(): Unit {
        ProbeRegistry.clear()
        let count = 24
        let futures = ArrayList<Future<Unit>>()
        for (i in 0..count) {
            let kind = "kind-${i}"
            futures.add(spawn {=> ProbeRegistry.registerAgent(kind, {=> RegistryProbeAgent(kind)}) })
        }
        for (future in futures) {
            future.get()
        }
        @Assert(ProbeRegistry.agents().size, count)

        ProbeRegistry.clear()
    }

    /** 查找不存在的 kind 返回 None。 */
    @TestCase
    public func missingKindReturnsNone(): Unit {
        ProbeRegistry.clear()
        @Assert(ProbeRegistry.agent("missing").isNone())
        ProbeRegistry.clear()
    }
}

class RegistryProbeAgent <: ProbeAgent {
    private let name: String

    public init(name: String) {
        this.name = name
    }

    public prop kind: String {
        get() {
            name
        }
    }

    public prop data: JsonObject {
        get() {
            JsonObject()
        }
    }
}

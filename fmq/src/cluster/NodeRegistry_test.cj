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
package fountain::fmq.cluster

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_protocol.default.{Message, MessageID}

@Test
class NodeRegistryTest {
    @TestCase
    public func nodeTableAndIdentity(): Unit {
        let registry = NodeRegistry(["h1:2350", "h2:2351", "h3:2352"], 1)
        @Assert(registry.nodeCount == 3)
        @Assert(registry.selfIndex == 1)
        @Assert(registry.nodeAt(0).getOrThrow()[0] == "h1")
        @Assert(registry.nodeAt(0).getOrThrow()[1] == 2350)
        @Assert(registry.nodeAt(9).isNone())
        @Assert(registry.indexOf("h2:2351") == Some(1))
        @Assert(registry.indexOf("nope:1").isNone())
        registry.close()
    }

    @TestCase
    public func selfNodeHasNoClient(): Unit {
        let registry = NodeRegistry(["h1:2350", "h2:2351"], 0)
        @Assert(registry.clientOf(0).isNone())
        registry.close()
    }

    @TestCase
    public func successorsWrapAround(): Unit {
        let registry = NodeRegistry(["h1:1", "h2:2", "h3:3"], 2)
        @Assert(registry.successors(2) == [0, 1])
        @Assert(registry.successors(0).size == 0)
        @Assert(registry.successors(99) == [0, 1])
        registry.close()
    }

    @TestCase
    public func singleNodeHasNoSuccessor(): Unit {
        let registry = NodeRegistry(["h1:1"], 0)
        @Assert(registry.successors(2).size == 0)
        registry.close()
    }

    @TestCase
    public func failedSendMarksNodeDead(): Unit {
        let registry = NodeRegistry(["127.0.0.1:1", "127.0.0.1:2"], 1, pingTimeout: Duration.millisecond * 100)
        @Assert(registry.isAlive(0))
        let response = registry.send(0, Message.ack(MessageID()))
        @Assert(response.isNone())
        @Assert(!registry.isAlive(0))
        registry.markSeen(0)
        @Assert(registry.isAlive(0))
        // 自身发送恒为 None
        @Assert(registry.send(1, Message.ack(MessageID())).isNone())
        registry.close()
        registry.close()
    }

    @TestCase
    public func invalidSelfIndexRejected(): Unit {
        var threw = false
        try {
            NodeRegistry(["h:1"], 3)
        } catch (_: IllegalArgumentException) {
            threw = true
        }
        @Assert(threw)
    }
}

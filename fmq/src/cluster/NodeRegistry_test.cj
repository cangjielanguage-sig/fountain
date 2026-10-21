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

import std.net.{IPSocketAddress, TcpServerSocket}
import std.unittest.*
import std.unittest.testmacro.*
import std.sync.AtomicInt64
import fountain::f_protocol.default.{Message, MessageID}

/** 起一个只接受连接的监听端口：只为让 `Client.build()` 能连上并交出可用句柄。 */
private func listeningSocket(): (TcpServerSocket, UInt16) {
    let listener = TcpServerSocket(bindAt: 0)
    listener.bind()
    var port: UInt16 = 0
    match (listener.localAddress) {
        case addr: IPSocketAddress => port = addr.port
        case _ => port = 0
    }
    let socket = listener
    spawn {
        while (true) {
            try {
                let accepted = socket.accept()
                accepted.close()
            } catch (_: Exception) {
                break
            }
        }
    }
    (listener, port)
}

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
        let builds = AtomicInt64(0)
        let registry = NodeRegistry(["127.0.0.1:1", "127.0.0.1:2"], 1, pingTimeout: Duration.millisecond * 100,
            clientBuilder: {_ =>
                builds.fetchAdd(1)
                throw Exception("unreachable")
            })
        // 存活标记初值是「未知」：必须靠一次成功调用才变成存活（A40）
        @Assert(!registry.isAlive(0))
        let response = registry.send(0, Message.ack(MessageID()))
        @Assert(response.isNone())
        @Assert(!registry.isAlive(0))
        @Assert(builds.load() == 1)
        registry.markSeen(0)
        @Assert(registry.isAlive(0))
        // 自身发送恒为 None
        @Assert(registry.send(1, Message.ack(MessageID())).isNone())
        registry.close()
        registry.close()
    }

    @TestCase
    public func revivalTriggersResyncOnlyOnce(): Unit {
        let registry = NodeRegistry(["127.0.0.1:1", "127.0.0.1:2"], 1)
        let revived = AtomicInt64(0)
        registry.onRevived = {=> revived.fetchAdd(1)}
        // 未知 → 存活：首次成功即视为上线，补一次同步
        registry.markSeen(0)
        @Assert(revived.load() == 1)
        // 继续存活：不重复触发
        registry.markSeen(0)
        @Assert(revived.load() == 1)
        // 死亡 → 复活：再触发一次
        registry.markFailed(0)
        registry.markSeen(0)
        @Assert(revived.load() == 2)
        registry.close()
    }

    /** 命中已关闭的连接必须重建，而不是把节点永久判死（A39）。 */
    @TestCase
    public func clientOfRebuildsClosedConnection(): Unit {
        let (listener, port) = listeningSocket()
        let registry = NodeRegistry(["127.0.0.1:${port}", "127.0.0.1:1"], 1,
            pingTimeout: Duration.millisecond * 200)
        try {
            let first = registry.clientOf(0).getOrThrow()
            @Assert(!first.isClosed())
            first.close()
            @Assert(first.isClosed())
            let second = registry.clientOf(0).getOrThrow()
            @Assert(!second.isClosed())
            @Assert(!refEq(first, second))
        } finally {
            registry.close()
            listener.close()
        }
    }

    /** 只有「最近一次调用失败」才算已知死亡；未知与存活都不算（A40）。 */
    @TestCase
    public func knownDeadOnlyAfterFailedCall(): Unit {
        let registry = NodeRegistry(["127.0.0.1:1", "127.0.0.1:2"], 1,
            pingTimeout: Duration.millisecond * 100,
            clientBuilder: {_ => throw Exception("unreachable")})
        try {
            @Assert(!registry.isKnownDead(0))
            @Assert(!registry.isAlive(0))
            registry.send(0, Message.ack(MessageID()))
            @Assert(registry.isKnownDead(0))
            registry.markSeen(0)
            @Assert(!registry.isKnownDead(0))
            @Assert(registry.isAlive(0))
        } finally {
            registry.close()
        }
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

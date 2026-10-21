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
package fountain::f_mq.client.test

import std.sync.{AtomicBool, AtomicInt64}
import std.time.DateTime
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.DataAny
import fountain::f_mq.base.MQProtocol
import fountain::f_mq.base.payload.MQResult
import fountain::f_mq.client.MQNodePool
import fountain::f_mq.exception.MQConnectionException
import fountain::f_net.SocketBuffer
import fountain::f_net.client.Client
import fountain::f_protocol.default.Message

@Test
class MQNodePoolTest {
    private static func ok(buffer: SocketBuffer, request: Message): ?Message {
        Some(MQProtocol.respond<MQResult>(request, MQResult(0, "ok")))
    }

    @TestCase
    public func lazilyBuildsAndCaches(): Unit {
        let stub = MQStubServer(ok).start()
        try {
            let pool = MQNodePool([stub.address()])
            @Assert(pool.aliveNodes() == [0])
            pool.clientOf(0)
            pool.clientOf(0)
            // 关闭后不可再用
            pool.close()
            pool.close()
            @Assert(pool.isClosed())
            @Assert(pool.aliveNodes().size == 0)
            var threw = false
            try {
                pool.clientOf(0)
            } catch (_: MQConnectionException) {
                threw = true
            }
            @Assert(threw)
        } finally {
            stub.close()
        }
    }

    @TestCase
    public func deadNodeThrows(): Unit {
        let pool = MQNodePool(["127.0.0.1:1"])
        var threw = false
        try {
            pool.clientOf(0)
        } catch (_: MQConnectionException) {
            threw = true
        }
        @Assert(threw)
        pool.close()
    }

    /** 命中已关闭的连接当场重建，而不是永久报错（A11）。 */
    @TestCase
    public func closedConnectionIsRebuilt(): Unit {
        let stub = MQStubServer(ok).start()
        try {
            let pool = MQNodePool([stub.address()])
            let first = pool.clientOf(0)
            @Assert(!first.isClosed())
            first.close()
            let second = pool.clientOf(0)
            @Assert(!second.isClosed())
            @Assert(!refEq(first, second))
            pool.close()
        } finally {
            stub.close()
        }
    }

    /** 一个节点建连慢不能拖住其它节点：建连只在节点锁内（A17）。 */
    @TestCase
    public func slowNodeDoesNotBlockOtherNodes(): Unit {
        let stub = MQStubServer(ok).start()
        let slowStarted = AtomicBool(false)
        let address = stub.address()
        let pool = MQNodePool(["slow:1", address], build: {entry =>
            if (entry == "slow:1") {
                slowStarted.store(true)
                sleep(Duration.millisecond * 1200)
                throw Exception("slow node is unreachable")
            }
            Client<DataAny>.builder(address: address, checkDuration: Duration.second * 30,
                checker: {=> Message.ping()}).pingTimeout(Duration.second).build()
        })
        try {
            spawn {
                try {
                    pool.clientOf(0)
                } catch (_: Exception) {}
            }
            var waited = 0
            while (!slowStarted.load() && waited < 200) {
                sleep(Duration.millisecond * 5)
                waited++
            }
            @Assert(slowStarted.load())
            let start = DateTime.now()
            let client = pool.clientOf(1)
            let elapsed = (DateTime.now() - start).toMilliseconds()
            @Assert(!client.isClosed())
            @Assert(elapsed < 300)
            pool.close()
        } finally {
            stub.close()
        }
    }

    /** 8 线程首次请求同一节点只建一条连接（A11）。 */
    @TestCase
    public func concurrentFirstUseBuildsOnce(): Unit {
        let stub = MQStubServer(ok).start()
        let builds = AtomicInt64(0)
        let address = stub.address()
        let pool = MQNodePool([address], build: {_ =>
            builds.fetchAdd(1)
            Client<DataAny>.builder(address: address, checkDuration: Duration.second * 30,
                checker: {=> Message.ping()}).pingTimeout(Duration.second).build()
        })
        try {
            let done = AtomicInt64(0)
            let failures = AtomicInt64(0)
            for (_ in 0..8) {
                spawn {
                    try {
                        pool.clientOf(0)
                    } catch (_: Exception) {
                        failures.fetchAdd(1)
                    }
                    done.fetchAdd(1)
                }
            }
            var waited = 0
            while (done.load() < 8 && waited < 500) {
                sleep(Duration.millisecond * 5)
                waited++
            }
            @Assert(done.load() == 8)
            @Assert(failures.load() == 0)
            @Assert(builds.load() == 1)
            pool.close()
        } finally {
            stub.close()
        }
    }

    /** 建连失败后退避：窗口内的再次调用立即失败，不再重撞（A11）。 */
    @TestCase
    public func failedBuildBacksOff(): Unit {
        let builds = AtomicInt64(0)
        let pool = MQNodePool(["dead:1"], build: {_ =>
            builds.fetchAdd(1)
            throw Exception("unreachable")
        })
        for (_ in 0..3) {
            try {
                pool.clientOf(0)
            } catch (_: MQConnectionException) {}
        }
        @Assert(builds.load() == 1)
        pool.close()
    }

    @TestCase
    public func invalidHostRejectedAtConstruction(): Unit {
        var threw = false
        try {
            MQNodePool(["no-port"])
        } catch (_: MQConnectionException) {
            threw = true
        }
        @Assert(threw)

        threw = false
        try {
            MQNodePool([])
        } catch (_: MQConnectionException) {
            threw = true
        }
        @Assert(threw)
    }
}

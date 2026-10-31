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

import std.collection.ArrayList
import std.collection.concurrent.ConcurrentHashMap
import std.sync.AtomicInt64
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.*
import fountain::f_data.macros.*
import fountain::f_mq.base.*
import fountain::f_mq.base.model.*
import fountain::f_mq.base.payload.*
import fountain::f_mq.client.{MQClient, MQRetiredSubscriptions}
import fountain::f_mq.exception.*
import fountain::f_net.SocketBuffer
import fountain::f_protocol.default.*
import fountain::f_util.UUID

private func longText(n: Int64): String {
    let buf = StringBuilder()
    for (_ in 0..n) {
        buf.append("a")
    }
    buf.toString()
}

@Test
class MQClientTest {
    private static func ok(buffer: SocketBuffer, request: Message): ?Message {
        Some(MQProtocol.respond<MQResult>(request, MQResult(0, "ok")))
    }

    private static func okBut(buffer: SocketBuffer, request: Message, code: Int64): ?Message {
        Some(MQProtocol.fail(request, code, MQErrorCode.messageOf(code)))
    }

    private static func countOf(stub: MQStubServer, command: String): Int64 {
        var count = 0i64
        for (message in stub.received()) {
            let matched = match (message.command) {
                case PUBLISH(_) => command == "PUBLISH"
                case SUBSCRIBE => command == "SUBSCRIBE"
                case UNSUBSCRIBE => command == "UNSUBSCRIBE"
                case CONSUME(_) => command == "CONSUME"
                case ACK => command == "ACK"
                case DEREGISTER => command == "DEREGISTER"
                case REGISTER => command == "REGISTER"
                case _ => false
            }
            if (matched) {
                count++
            }
        }
        count
    }

    private static func stubMessage(topic: String, index: Int64, offset: Int64,
        queueIndex!: Int64 = 0): MQConsumeResult {
        let record = MQMessageRecord.encode(topic, ["a"], "m-${index}-${offset}", "body-${index}".toData())
        MQConsumeResult(queueIndex, index, offset, record)
    }

    /** 非法 tags / 组名在本地失败，一个请求都不发（A19/A05）。 */
    @TestCase
    public func invalidTagsAndGroupFailBeforeAnyRequest(): Unit {
        let stub = MQStubServer(ok).start()
        try {
            let client = MQClient([stub.address()])
            var failed = 0
            try {
                client.publish("/order", "hi", tags: [""])
            } catch (_: MQException) {
                failed++
            }
            try {
                client.publish("/order", "hi", tags: ["a b"])
            } catch (_: MQException) {
                failed++
            }
            try {
                client.publish("/order", "hi", tags: Array<String>(65, repeat: "t"))
            } catch (_: MQException) {
                failed++
            }
            try {
                client.publish("/order", "hi", tags: [longText(129)])
            } catch (_: MQException) {
                failed++
            }
            try {
                client.subscribe("/order", tags: ["bad tag"])
            } catch (_: MQException) {
                failed++
            }
            try {
                client.subscribe("/order", subscribeGroup: "g:1")
            } catch (_: MQException) {
                failed++
            }
            @Assert(failed == 6)
            @Assert(stub.received().size == 0)
            client.close()
        } finally {
            stub.close()
        }
    }

    @TestCase
    public func publishSendsRecordAndAlignsMessageId(): Unit {
        let stub = MQStubServer(ok).start()
        try {
            let client = MQClient([stub.address()])
            client.publish("/order", "hello", tags: ["x", "y"])
            let requests = stub.received()
            @Assert(requests.size == 1)
            let request = requests[0]
            match (request.command) {
                case PUBLISH(_) => @Assert(true)
                case _ => @Assert(false)
            }
            let record = MQProtocol.asRecord(request).getOrThrow()
            let content = MQMessageRecord.decode(record).getOrThrow()
            @Assert(content.topic == "/order")
            @Assert(content.tags == ["x", "y"])
            @Assert(convert<String>(content.body.data) == Some("hello"))
            // 帧 id 与记录内的 MESSAGE_ID 一致
            @Assert(content.messageId == request.id.toString())
            // 内存里的 MessageID 必须带集群主机号：pid/tid 跨机器会重复，只有 hostId 能区分节点
            @Assert(request.id.hostId == ProtocolConfig.getProtocolHostId())
            @Assert(request.id.hostId != 0)
            @Assert(content.messageId.split("_")[2] == request.id.hostId.toString())
            client.close()
        } finally {
            stub.close()
        }
    }

    @TestCase
    public func publishFallsBackFromNotOwnerAndCachesOwner(): Unit {
        let stub0 = MQStubServer({buffer, request => okBut(buffer, request, MQErrorCode.NOT_OWNER)}).start()
        let stub1 = MQStubServer(ok).start()
        try {
            let client = MQClient([stub0.address(), stub1.address()])
            client.publish("/order", 1i64)
            @Assert(countOf(stub0, "PUBLISH") == 1)
            @Assert(countOf(stub1, "PUBLISH") == 1)
            // 缓存被修正为实际 owner：第二次直接命中节点 1
            client.publish("/order", 2i64)
            @Assert(countOf(stub0, "PUBLISH") == 1)
            @Assert(countOf(stub1, "PUBLISH") == 2)
            client.close()
        } finally {
            stub0.close()
            stub1.close()
        }
    }

    @TestCase
    public func publishTopicNotExistThrowsServiceException(): Unit {
        let stub = MQStubServer({buffer, request => okBut(buffer, request,
            MQErrorCode.TOPIC_NOT_EXIST)}).start()
        try {
            let client = MQClient([stub.address()])
            var code = -1i64
            try {
                client.publish("/missing", 1i64)
            } catch (e: MQServiceException) {
                code = e.code
            }
            @Assert(code == MQErrorCode.TOPIC_NOT_EXIST)
            client.close()
        } finally {
            stub.close()
        }
    }

    @TestCase
    public func invalidTopicFailsLocally(): Unit {
        let stub = MQStubServer(ok).start()
        try {
            let client = MQClient([stub.address()])
            var threw = false
            try {
                client.publish("order", 1i64)
            } catch (_: MQException) {
                threw = true
            }
            @Assert(threw)
            @Assert(stub.receivedCount() == 0)
            client.close()
        } finally {
            stub.close()
        }
    }

    @TestCase
    public func allNodesUnreachableThrowsConnectionException(): Unit {
        let client = MQClient(["127.0.0.1:1"])
        var threw = false
        try {
            client.publish("/t", 1i64)
        } catch (_: MQConnectionException) {
            threw = true
        }
        @Assert(threw)
        client.close()
    }

    @TestCase
    public func subscribeBroadcastsSamePayload(): Unit {
        let stub0 = MQStubServer(ok).start()
        let stub1 = MQStubServer(ok).start()
        try {
            let client = MQClient([stub0.address(), stub1.address()])
            let sid = client.subscribe("/order", subscribeGroup: "g1", tags: ["a"], filter: "$.enabled",
                autoAck: true)
            @Assert(UUID.tryParse(sid).isSome())

            let payloads = ArrayList<MQSubscribePayload>()
            for (stub in [stub0, stub1]) {
                for (message in stub.received()) {
                    if (message.command == SUBSCRIBE) {
                        payloads.add(MQProtocol.asPayload<MQSubscribePayload>(message).getOrThrow())
                    }
                }
            }
            @Assert(payloads.size == 2)
            for (payload in payloads) {
                @Assert(payload.subscribedId == sid)
                @Assert(payload.topic == "/order")
                @Assert(payload.subscribeGroup == "g1")
                @Assert(payload.tags == ["a"])
                @Assert(payload.filter == "$.enabled")
                @Assert(payload.autoAck)
            }
            client.close()
        } finally {
            stub0.close()
            stub1.close()
        }
    }

    @TestCase
    public func subscribeRollsBackOnGroupNotExist(): Unit {
        let stub0 = MQStubServer(ok).start()
        let stub1 = MQStubServer({buffer, request => okBut(buffer, request,
            MQErrorCode.GROUP_NOT_EXIST)}).start()
        try {
            let client = MQClient([stub0.address(), stub1.address()])
            var code = -1i64
            try {
                client.subscribe("/order", subscribeGroup: "missing")
            } catch (e: MQServiceException) {
                code = e.code
            }
            @Assert(code == MQErrorCode.GROUP_NOT_EXIST)
            // 已接受的节点收到回滚
            @Assert(countOf(stub0, "UNSUBSCRIBE") == 1)
            client.close()
        } finally {
            stub0.close()
            stub1.close()
        }
    }

    @TestCase
    public func subscribeDefaultGroupAndInvalidFilter(): Unit {
        let stub = MQStubServer(ok).start()
        try {
            let client = MQClient([stub.address()])
            client.subscribe("/order")
            let payload = MQProtocol.asPayload<MQSubscribePayload>(stub.received()[0]).getOrThrow()
            @Assert(payload.subscribeGroup.isEmpty())
            @Assert(!payload.autoAck)

            // 非法过滤器本地失败，不发请求
            let before = stub.receivedCount()
            var threw = false
            try {
                client.subscribe("/order", filter: "order")
            } catch (_: Exception) {
                threw = true
            }
            @Assert(threw)
            @Assert(stub.receivedCount() == before)
            client.close()
        } finally {
            stub.close()
        }
    }

    @TestCase
    public func consumeDecodesMessageAndFillsPosition(): Unit {
        let stub = MQStubServer({buffer, request =>
            match (request.command) {
                case CONSUME(_) => Some(MQProtocol.respond<MQConsumeResult>(request, stubMessage("/order", 7, 128)))
                case _ => Some(MQProtocol.respond<MQResult>(request, MQResult(0, "ok")))
            }
        }).start()
        try {
            let client = MQClient([stub.address()])
            let sid = client.subscribe("/order")
            let message = client.consume(sid)
            @Assert(message.topic == "/order")
            @Assert(message.tags == ["a"])
            @Assert(message.segmentedIndex == 7)
            @Assert(message.segmentedOffset == 128)
            @Assert(message.get<String>() == Some("body-7"))
            client.close()
        } finally {
            stub.close()
        }
    }

    @TestCase
    public func consumeEmptyMovesToNextOwner(): Unit {
        let stub0 = MQStubServer({buffer, request =>
            match (request.command) {
                case CONSUME(_) => Some(MQProtocol.respond<MQConsumeResult>(request, MQConsumeResult()))
                case _ => Some(MQProtocol.respond<MQResult>(request, MQResult(0, "ok")))
            }
        }).start()
        let stub1 = MQStubServer({buffer, request =>
            match (request.command) {
                case CONSUME(_) => Some(MQProtocol.respond<MQConsumeResult>(request, stubMessage("/order", 1, 0)))
                case _ => Some(MQProtocol.respond<MQResult>(request, MQResult(0, "ok")))
            }
        }).start()
        try {
            let client = MQClient([stub0.address(), stub1.address()])
            let sid = client.subscribe("/order")
            let message = client.consume(sid)
            @Assert(message.segmentedIndex == 1)
            // 同一轮里 node0 只被请求一次
            @Assert(countOf(stub0, "CONSUME") == 1)
            @Assert(countOf(stub1, "CONSUME") == 1)
            client.close()
        } finally {
            stub0.close()
            stub1.close()
        }
    }

    /** 全部 owner 不可达时 consume 必须抛错，而不是永久空转（A12）。 */
    @TestCase
    public func consumeThrowsWhenAllOwnersUnreachable(): Unit {
        let stub = MQStubServer(ok).start()
        let client = MQClient([stub.address()])
        let sid = client.subscribe("/order")
        stub.close()
        var threw = false
        var text = ""
        try {
            client.consume(sid)
        } catch (e: MQConnectionException) {
            threw = true
            text = e.message
        }
        @Assert(threw)
        // 场景「全部 owner 不可达」要求文案包含尝试过的节点：单节点客户端即节点 0
        @Assert(text.contains("[0]"))
        client.close()
    }

    /** 全部 NOT_OWNER 是服务端确定答案，必须抛服务异常而不是连接异常（A18）。 */
    @TestCase
    public func publishAllNotOwnerRaisesServiceException(): Unit {
        let stub = MQStubServer({buffer, request => okBut(buffer, request, MQErrorCode.NOT_OWNER)}).start()
        try {
            let client = MQClient([stub.address()])
            var code = -1i64
            try {
                client.publish("/t", 1i64)
            } catch (e: MQServiceException) {
                code = e.code
            }
            @Assert(code == MQErrorCode.NOT_OWNER)
            client.close()
        } finally {
            stub.close()
        }
    }

    /** `FILTER_UNSUPPORTED_BODY` 等错误码必须抛给调用方（A16）。 */
    @TestCase
    public func consumeMapsServiceErrorCode(): Unit {
        let stub = MQStubServer({buffer, request =>
            match (request.command) {
                case CONSUME(_) => okBut(buffer, request, MQErrorCode.FILTER_UNSUPPORTED_BODY)
                case _ => Some(MQProtocol.respond<MQResult>(request, MQResult(0, "ok")))
            }
        }).start()
        try {
            let client = MQClient([stub.address()])
            let sid = client.subscribe("/order")
            var code = -1i64
            try {
                client.consume(sid)
            } catch (e: MQServiceException) {
                code = e.code
            }
            @Assert(code == MQErrorCode.FILTER_UNSUPPORTED_BODY)
            client.close()
        } finally {
            stub.close()
        }
    }

    /** 非空记录解码失败不能当成「没有消息」继续轮询（A16）。 */
    @TestCase
    public func consumeFailsOnUndecodableRecord(): Unit {
        let stub = MQStubServer({buffer, request =>
            match (request.command) {
                case CONSUME(_) =>
                    Some(MQProtocol.respond<MQConsumeResult>(request,
                        MQConsumeResult(0, 1, 0, [1u8, 2u8, 3u8])))
                case _ => Some(MQProtocol.respond<MQResult>(request, MQResult(0, "ok")))
            }
        }).start()
        try {
            let client = MQClient([stub.address()])
            let sid = client.subscribe("/order")
            var code = -1i64
            try {
                client.consume(sid)
            } catch (e: MQServiceException) {
                code = e.code
            }
            @Assert(code == MQErrorCode.INTERNAL)
            client.close()
        } finally {
            stub.close()
        }
    }

    /** ack 的失败必须可见：非 ACK_UNKNOWN 抛服务异常，ACK_UNKNOWN 视为已处理（A13）。 */
    @TestCase
    public func ackSurfacesFailuresExceptUnknown(): Unit {
        let internalError = MQStubServer({buffer, request =>
            match (request.command) {
                case ACK => okBut(buffer, request, MQErrorCode.INTERNAL)
                case CONSUME(_) => Some(MQProtocol.respond<MQConsumeResult>(request, stubMessage("/order", 1, 0)))
                case _ => Some(MQProtocol.respond<MQResult>(request, MQResult(0, "ok")))
            }
        }).start()
        let unknownAck = MQStubServer({buffer, request =>
            match (request.command) {
                case ACK => okBut(buffer, request, MQErrorCode.ACK_UNKNOWN)
                case CONSUME(_) => Some(MQProtocol.respond<MQConsumeResult>(request, stubMessage("/order", 1, 0)))
                case _ => Some(MQProtocol.respond<MQResult>(request, MQResult(0, "ok")))
            }
        }).start()
        try {
            let failing = MQClient([internalError.address()])
            let sid0 = failing.subscribe("/order")
            let first = failing.consume(sid0)
            var code = -1i64
            try {
                failing.ack(sid0, first.queueIndex, first.segmentedIndex, first.segmentedOffset)
            } catch (e: MQServiceException) {
                code = e.code
            }
            @Assert(code == MQErrorCode.INTERNAL)
            failing.close()

            let tolerant = MQClient([unknownAck.address()])
            let sid1 = tolerant.subscribe("/order")
            let second = tolerant.consume(sid1)
            // ACK_UNKNOWN 不抛
            tolerant.ack(sid1, second.queueIndex, second.segmentedIndex, second.segmentedOffset)
            tolerant.close()
        } finally {
            internalError.close()
            unknownAck.close()
        }
    }

    /** unsubscribe 部分失败必须抛错且保留本地订阅，重试仍会发请求（A14）。 */
    @TestCase
    public func unsubscribePartialFailureKeepsSubscription(): Unit {
        let good = MQStubServer(ok).start()
        let bad = MQStubServer({buffer, request =>
            match (request.command) {
                case UNSUBSCRIBE => okBut(buffer, request, MQErrorCode.INTERNAL)
                case _ => Some(MQProtocol.respond<MQResult>(request, MQResult(0, "ok")))
            }
        }).start()
        try {
            let client = MQClient([good.address(), bad.address()])
            let sid = client.subscribe("/order")
            var threw = false
            try {
                client.unsubscribe(sid)
            } catch (_: MQConnectionException) {
                threw = true
            }
            @Assert(threw)
            @Assert(countOf(good, "UNSUBSCRIBE") == 1)
            // 本地订阅仍在：再退一次仍会发请求（而不是 SUBSCRIBE_NOT_EXIST）
            let again = try {
                client.unsubscribe(sid)
                false
            } catch (_: Exception) {
                true
            }
            @Assert(again)
            @Assert(countOf(good, "UNSUBSCRIBE") == 2)
            client.close()
        } finally {
            good.close()
            bad.close()
        }
    }

    /** 同一位置只允许一个线程认领：服务端重投窗口内的重复位置不能被两个消费者同时拿走（A20）。 */
    @TestCase
    public func sameDeliveryPositionIsClaimedOnce(): Unit {
        let stub = MQStubServer({buffer, request =>
            match (request.command) {
                case CONSUME(_) => Some(MQProtocol.respond<MQConsumeResult>(request, stubMessage("/order", 1, 0)))
                case _ => Some(MQProtocol.respond<MQResult>(request, MQResult(0, "ok")))
            }
        }).start()
        let client = MQClient([stub.address()])
        let sid = client.subscribe("/order")
        let delivered = AtomicInt64(0)
        try {
            for (_ in 0..2) {
                spawn {
                    try {
                        client.consume(sid)
                        delivered.fetchAdd(1)
                    } catch (_: Exception) {
                        ()
                    }
                    ()
                }
            }
            var waited = 0
            while (delivered.load() == 0 && waited < 400) {
                sleep(Duration.millisecond * 10)
                waited++
            }
            // 给另一个线程足够的轮询时间：它必须一直被认领失败挡住
            sleep(Duration.millisecond * 600)
            @Assert(delivered.load() == 1)
        } finally {
            client.close()
            stub.close()
        }
    }

    /** ack 释放位置后，同一位置可以被重新认领（重投语义）（A20）。 */
    @TestCase
    public func ackReleasesPositionForRedelivery(): Unit {
        let stub = MQStubServer({buffer, request =>
            match (request.command) {
                case CONSUME(_) => Some(MQProtocol.respond<MQConsumeResult>(request, stubMessage("/order", 1, 0)))
                case _ => Some(MQProtocol.respond<MQResult>(request, MQResult(0, "ok")))
            }
        }).start()
        try {
            let client = MQClient([stub.address()])
            let sid = client.subscribe("/order")
            let first = client.consume(sid)
            client.ack(sid, first.queueIndex, first.segmentedIndex, first.segmentedOffset)
            let second = client.consume(sid)
            @Assert(second.segmentedIndex == first.segmentedIndex)
            @Assert(second.segmentedOffset == first.segmentedOffset)
            client.close()
        } finally {
            stub.close()
        }
    }

    @TestCase
    public func consumeWaitsUntilMessageArrives(): Unit {
        let calls = AtomicInt64(0)
        let stub = MQStubServer({buffer, request =>
            match (request.command) {
                case CONSUME(_) =>
                    if (calls.fetchAdd(1) < 2) {
                        Some(MQProtocol.respond<MQConsumeResult>(request, MQConsumeResult()))
                    } else {
                        Some(MQProtocol.respond<MQConsumeResult>(request, stubMessage("/order", 3, 0)))
                    }
                case _ => Some(MQProtocol.respond<MQResult>(request, MQResult(0, "ok")))
            }
        }).start()
        try {
            let client = MQClient([stub.address()])
            let sid = client.subscribe("/order")
            let message = client.consume(sid)
            @Assert(message.segmentedIndex == 3)
            @Assert(countOf(stub, "CONSUME") == 3)
            client.close()
        } finally {
            stub.close()
        }
    }

    @TestCase
    public func consumeThrowsWhenSubscriptionGone(): Unit {
        let stub = MQStubServer({buffer, request =>
            match (request.command) {
                case CONSUME(_) => okBut(buffer, request, MQErrorCode.SUBSCRIBE_NOT_EXIST)
                case _ => Some(MQProtocol.respond<MQResult>(request, MQResult(0, "ok")))
            }
        }).start()
        try {
            let client = MQClient([stub.address()])
            let sid = client.subscribe("/order")
            var code = -1i64
            try {
                client.consume(sid)
            } catch (e: MQServiceException) {
                code = e.code
            }
            @Assert(code == MQErrorCode.SUBSCRIBE_NOT_EXIST)
            client.close()
        } finally {
            stub.close()
        }
    }

    @TestCase
    public func ackGoesBackToDeliveryNode(): Unit {
        let stub0 = MQStubServer({buffer, request =>
            match (request.command) {
                case CONSUME(_) => Some(MQProtocol.respond<MQConsumeResult>(request, MQConsumeResult()))
                case _ => Some(MQProtocol.respond<MQResult>(request, MQResult(0, "ok")))
            }
        }).start()
        let stub1 = MQStubServer({buffer, request =>
            match (request.command) {
                case CONSUME(_) => Some(MQProtocol.respond<MQConsumeResult>(request, stubMessage("/order", 2, 9)))
                case _ => Some(MQProtocol.respond<MQResult>(request, MQResult(0, "ok")))
            }
        }).start()
        try {
            let client = MQClient([stub0.address(), stub1.address()])
            let sid = client.subscribe("/order")
            let message = client.consume(sid)
            client.ack(sid, message.queueIndex, message.segmentedIndex, message.segmentedOffset)
            @Assert(countOf(stub1, "ACK") == 1)
            @Assert(countOf(stub0, "ACK") == 0)
            client.close()
        } finally {
            stub0.close()
            stub1.close()
        }
    }

    @TestCase
    public func ackPayloadKeepsQueueIdentity(): Unit {
        // 同一节点、同一位置 (1, 0) 先后来自队列 0 与队列 2：ACK 必须携带各自的 queueIndex
        let calls = AtomicInt64(0)
        let stub = MQStubServer({buffer, request =>
            match (request.command) {
                case CONSUME(_) =>
                    let n = calls.fetchAdd(1)
                    if (n == 0) {
                        Some(MQProtocol.respond<MQConsumeResult>(request, stubMessage("/order", 1, 0, queueIndex: 0)))
                    } else {
                        Some(MQProtocol.respond<MQConsumeResult>(request, stubMessage("/order", 1, 0, queueIndex: 2)))
                    }
                case _ => Some(MQProtocol.respond<MQResult>(request, MQResult(0, "ok")))
            }
        }).start()
        try {
            let client = MQClient([stub.address()])
            let sid = client.subscribe("/order")
            let first = client.consume(sid)
            let second = client.consume(sid)
            @Assert(first.queueIndex == 0)
            @Assert(second.queueIndex == 2)
            @Assert(first.segmentedIndex == second.segmentedIndex)
            @Assert(first.segmentedOffset == second.segmentedOffset)
            client.ack(sid, first.queueIndex, first.segmentedIndex, first.segmentedOffset)
            client.ack(sid, second.queueIndex, second.segmentedIndex, second.segmentedOffset)
            let seen = ArrayList<Int64>()
            for (message in stub.received()) {
                if (message.command == Command.ACK) {
                    seen.add(MQProtocol.asPayload<MQAckPayload>(message).getOrThrow().queueIndex)
                }
            }
            @Assert(seen.size == 2)
            @Assert(seen[0] == 0)
            @Assert(seen[1] == 2)
            client.close()
        } finally {
            stub.close()
        }
    }

    @TestCase
    public func unknownPositionAckBroadcastsAndIgnoresErrors(): Unit {
        let stub0 = MQStubServer({buffer, request =>
            match (request.command) {
                case ACK => okBut(buffer, request, MQErrorCode.ACK_UNKNOWN)
                case _ => Some(MQProtocol.respond<MQResult>(request, MQResult(0, "ok")))
            }
        }).start()
        let stub1 = MQStubServer({buffer, request =>
            match (request.command) {
                case ACK => okBut(buffer, request, MQErrorCode.ACK_UNKNOWN)
                case _ => Some(MQProtocol.respond<MQResult>(request, MQResult(0, "ok")))
            }
        }).start()
        try {
            let client = MQClient([stub0.address(), stub1.address()])
            let sid = client.subscribe("/order")
            client.ack(sid, 0, 99, 100)
            @Assert(countOf(stub0, "ACK") == 1)
            @Assert(countOf(stub1, "ACK") == 1)
            client.close()
        } finally {
            stub0.close()
            stub1.close()
        }
    }

    @TestCase
    public func autoAckDoesNotRecordDeliveryAndStillAcks(): Unit {
        let stub0 = MQStubServer(ok).start()
        let stub1 = MQStubServer(ok).start()
        try {
            let client = MQClient([stub0.address(), stub1.address()])
            let sid = client.subscribe("/order", autoAck: true)
            client.ack(sid, 0, 1, 2)
            // autoAck 不记录投递来源 ⇒ 广播
            @Assert(countOf(stub0, "ACK") == 1)
            @Assert(countOf(stub1, "ACK") == 1)
            client.close()
        } finally {
            stub0.close()
            stub1.close()
        }
    }

    /**
     * 退订幂等：同一 id 退两次都成功，第二次纯本地空操作；
     * 从未订阅过的 id 抛服务异常且不发请求（R5-4）。
     */
    @TestCase
    public func unsubscribeIsIdempotentOnServerAndRejectsUnknownId(): Unit {
        let stub = MQStubServer({buffer, request =>
            match (request.command) {
                case UNSUBSCRIBE => okBut(buffer, request, MQErrorCode.SUBSCRIBE_NOT_EXIST)
                case _ => Some(MQProtocol.respond<MQResult>(request, MQResult(0, "ok")))
            }
        }).start()
        try {
            let client = MQClient([stub.address()])
            let sid = client.subscribe("/order")
            // 服务端回 SUBSCRIBE_NOT_EXIST 视为成功
            client.unsubscribe(sid)
            @Assert(countOf(stub, "UNSUBSCRIBE") == 1)

            // 已退订的 id 再退一次：成功，且不再发请求
            let before = stub.receivedCount()
            client.unsubscribe(sid)
            @Assert(stub.receivedCount() == before)

            // 从未订阅过的 id：抛异常且不发请求
            var code = -1i64
            try {
                client.unsubscribe("never-subscribed")
            } catch (e: MQServiceException) {
                code = e.code
            }
            @Assert(code == MQErrorCode.SUBSCRIBE_NOT_EXIST)
            @Assert(stub.receivedCount() == before)
            client.close()
        } finally {
            stub.close()
        }
    }

    /** 退订记忆有界：超出容量后最老的 id 被淘汰，再退订视为未知（R5-4）。 */
    @TestCase
    public func retiredSubscriptionsEvictOldestBeyondCapacity(): Unit {
        let retired = MQRetiredSubscriptions(capacity: 2)
        retired.add("a")
        retired.add("b")
        @Assert(retired.contains("a"))
        @Assert(retired.contains("b"))
        retired.add("c")
        @Assert(!retired.contains("a"))
        @Assert(retired.contains("b"))
        @Assert(retired.contains("c"))
        // 重复加入不刷新位置：加入 d 时仍按 FIFO 淘汰最老的 b
        retired.add("b")
        retired.add("d")
        @Assert(!retired.contains("b"))
        @Assert(retired.contains("c"))
        @Assert(retired.contains("d"))
    }

    @TestCase
    public func closeIsIdempotentAndBlocksApis(): Unit {
        let stub = MQStubServer(ok).start()
        try {
            let client = MQClient([stub.address()])
            client.close()
            client.close()
            @Assert(client.isClosed())

            var threw = 0
            try {
                client.publish("/t", 1i64)
            } catch (_: MQConnectionException) {
                threw++
            }
            try {
                client.subscribe("/t")
            } catch (_: MQConnectionException) {
                threw++
            }
            try {
                client.consume("none")
            } catch (_: MQConnectionException) {
                threw++
            }
            try {
                client.ack("none", 0, 0, 0)
            } catch (_: MQConnectionException) {
                threw++
            }
            @Assert(threw == 4)
        } finally {
            stub.close()
        }
    }

    @TestCase
    public func concurrentConsumersGetUniquePositions(): Unit {
        let counter = AtomicInt64(0)
        let stub = MQStubServer({buffer, request =>
            match (request.command) {
                case CONSUME(_) =>
                    let n = counter.fetchAdd(1)
                    Some(MQProtocol.respond<MQConsumeResult>(request, stubMessage("/order", n, 0)))
                case _ => Some(MQProtocol.respond<MQResult>(request, MQResult(0, "ok")))
            }
        }).start()
        try {
            let client = MQClient([stub.address()])
            let sid = client.subscribe("/order")
            let seen = ConcurrentHashMap<String, Bool>()
            let done = AtomicInt64(0)
            for (_ in 0..4) {
                spawn {
                    for (_ in 0..50) {
                        let message = client.consume(sid)
                        seen.addIfAbsent("${message.segmentedIndex}:${message.segmentedOffset}", true)
                    }
                    done.fetchAdd(1)
                }
            }
            var waited = 0
            while (done.load() < 4 && waited < 300) {
                sleep(Duration.millisecond * 20)
                waited++
            }
            @Assert(done.load() == 4)
            @Assert(seen.size == 200)
            client.close()
        } finally {
            stub.close()
        }
    }

    /** 全部节点都回 NOT_OWNER：没有 owner，必须明确报错（A21）。 */
    @TestCase
    public func subscribeWithNoOwnerThrows(): Unit {
        let stub = MQStubServer({buffer, request => okBut(buffer, request, MQErrorCode.NOT_OWNER)}).start()
        try {
            let client = MQClient([stub.address()])
            var message = ""
            try {
                client.subscribe("/order")
            } catch (e: MQConnectionException) {
                message = e.message
            }
            @Assert(message.contains("no node owns"))
            client.close()
        } finally {
            stub.close()
        }
    }

    /** 订阅时全部节点不可达：抛连接异常而不是留下半个订阅（A21）。 */
    @TestCase
    public func subscribeWithAllNodesUnreachableThrows(): Unit {
        let stub = MQStubServer(ok).start()
        let client = MQClient([stub.address()])
        stub.close()
        var threw = false
        try {
            client.subscribe("/order")
        } catch (_: MQConnectionException) {
            threw = true
        }
        @Assert(threw)
        client.close()
    }

    /** 对端不回应答：publish 超时后抛连接异常，不得永久挂起（A21）。 */
    @TestCase
    public func publishTimesOutWhenServerSilent(): Unit {
        let stub = MQStubServer({_, _ => None<Message>}).start()
        try {
            let client = MQClient([stub.address()])
            var threw = false
            try {
                client.publish("/order", 1i64)
            } catch (_: MQConnectionException) {
                threw = true
            }
            @Assert(threw)
            client.close()
        } finally {
            stub.close()
        }
    }

    /** 关闭与在途调用并发：只允许抛 MQ 异常，不得空引用崩溃（A71）。 */
    @TestCase
    public func closeIsSafeUnderConcurrentCalls(): Unit {
        let stub = MQStubServer(ok).start()
        let client = MQClient([stub.address()])
        let unexpected = AtomicInt64(0)
        let completed = AtomicInt64(0)
        for (_ in 0..8) {
            spawn {
                for (_ in 0..50) {
                    try {
                        client.publish("/order", 1i64)
                    } catch (e: Exception) {
                        if (!(e is MQException)) {
                            unexpected.fetchAdd(1)
                        }
                    }
                }
                completed.fetchAdd(1)
            }
        }
        sleep(Duration.millisecond * 20)
        client.close()
        var waited = 0
        while (completed.load() < 8 && waited < 500) {
            sleep(Duration.millisecond * 10)
            waited++
        }
        try {
            @Assert(completed.load() == 8)
            @Assert(unexpected.load() == 0)
        } finally {
            stub.close()
        }
    }

    /** 全部节点不可达时，每个节点都要留下含下标与地址的 WARN/ERROR（A16）。 */
    @TestCase
    public func clientFailsWithPerNodeLogs(): Unit {
        CapturingAppender.install()
        let hosts = ["127.0.0.1:1", "127.0.0.1:2"]
        let client = MQClient(hosts)
        try {
            var threw = false
            try {
                client.publish("/order", 1i64)
            } catch (_: MQConnectionException) {
                threw = true
            }
            @Assert(threw)
            for (i in 0..hosts.size) {
                @Assert(CapturingAppender.waitFor(["node ${i}", hosts[i]]))
            }
        } finally {
            client.close()
        }
    }

    /** 记录解码失败时，ERROR 日志要含订阅 id、队列与位置（A16）。 */
    @TestCase
    public func decodeFailureLogsPosition(): Unit {
        CapturingAppender.install()
        let stub = MQStubServer({buffer, request =>
            match (request.command) {
                case CONSUME(_) =>
                    Some(MQProtocol.respond<MQConsumeResult>(request,
                        MQConsumeResult(0, 1, 0, [1u8, 2u8, 3u8])))
                case _ => Some(MQProtocol.respond<MQResult>(request, MQResult(0, "ok")))
            }
        }).start()
        try {
            let client = MQClient([stub.address()])
            let sid = client.subscribe("/order")
            try {
                client.consume(sid)
            } catch (_: MQServiceException) {
                ()
            }
            @Assert(CapturingAppender.waitFor([sid, "0:1:0", "3 bytes"]))
            client.close()
        } finally {
            stub.close()
        }
    }

    /** 解码失败日志同时要带主题，排障才能定位到订阅（R1-G2）。 */
    @TestCase
    public func decodeFailureLogsSubscriptionAndTopic(): Unit {
        CapturingAppender.install()
        let stub = MQStubServer({buffer, request =>
            match (request.command) {
                case CONSUME(_) =>
                    Some(MQProtocol.respond<MQConsumeResult>(request,
                        MQConsumeResult(0, 1, 0, [1u8, 2u8, 3u8])))
                case _ => Some(MQProtocol.respond<MQResult>(request, MQResult(0, "ok")))
            }
        }).start()
        try {
            let client = MQClient([stub.address()])
            let sid = client.subscribe("/order")
            try {
                client.consume(sid)
            } catch (_: MQServiceException) {
                ()
            }
            @Assert(CapturingAppender.waitFor([sid, "/order", "cannot decode record"]))
            client.close()
        } finally {
            stub.close()
        }
    }

    /** 退订失败日志要带订阅 id 与主题（R1-G2）。 */
    @TestCase
    public func unsubscribeFailureLogsSubscriptionAndTopic(): Unit {
        CapturingAppender.install()
        let stub = MQStubServer({buffer, request =>
            match (request.command) {
                case UNSUBSCRIBE => okBut(buffer, request, MQErrorCode.INTERNAL)
                case _ => Some(MQProtocol.respond<MQResult>(request, MQResult(0, "ok")))
            }
        }).start()
        try {
            let client = MQClient([stub.address()])
            let sid = client.subscribe("/order", subscribeGroup: "g1")
            try {
                client.unsubscribe(sid)
            } catch (_: MQConnectionException) {
                ()
            }
            @Assert(CapturingAppender.waitFor([sid, "/order", "unsubscribe"]))
            client.close()
        } finally {
            stub.close()
        }
    }

    /** 回滚失败要报出失败节点，并在 ERROR 日志里带订阅 id 与主题（R1-G11）。 */
    @TestCase
    public func rollbackFailureReportsNodeAndLogsContext(): Unit {
        CapturingAppender.install()
        let accepted = MQStubServer({buffer, request =>
            match (request.command) {
                case UNSUBSCRIBE => okBut(buffer, request, MQErrorCode.INTERNAL)
                case _ => Some(MQProtocol.respond<MQResult>(request, MQResult(0, "ok")))
            }
        }).start()
        let rejected = MQStubServer({buffer, request => okBut(buffer, request, MQErrorCode.GROUP_NOT_EXIST)}).start()
        try {
            let client = MQClient([accepted.address(), rejected.address()])
            var text = ""
            try {
                client.subscribe("/order", subscribeGroup: "g1")
            } catch (e: MQServiceException) {
                text = e.message
            }
            // 回滚失败的节点下标必须出现在异常文案里
            @Assert(text.contains("0("))
            @Assert(CapturingAppender.waitFor(["rollback", "0(", "/order"]))
            client.close()
        } finally {
            accepted.close()
            rejected.close()
        }
    }

    /** ack 发送失败保留投递映射，重试成功后映射才删除（R1-G14）。 */
    @TestCase
    public func ackFailureKeepsDeliveryMappingAndRetryClearsIt(): Unit {
        let acks = AtomicInt64(0)
        let empty = MQStubServer({buffer, request =>
            match (request.command) {
                case CONSUME(_) => Some(MQProtocol.respond<MQConsumeResult>(request, MQConsumeResult()))
                case _ => Some(MQProtocol.respond<MQResult>(request, MQResult(0, "ok")))
            }
        }).start()
        let owner = MQStubServer({buffer, request =>
            match (request.command) {
                case CONSUME(_) => Some(MQProtocol.respond<MQConsumeResult>(request, stubMessage("/order", 1, 0)))
                case ACK =>
                    if (acks.fetchAdd(1) == 0) {
                        okBut(buffer, request, MQErrorCode.INTERNAL)
                    } else {
                        Some(MQProtocol.respond<MQResult>(request, MQResult(0, "ok")))
                    }
                case _ => Some(MQProtocol.respond<MQResult>(request, MQResult(0, "ok")))
            }
        }).start()
        try {
            let client = MQClient([empty.address(), owner.address()])
            let sid = client.subscribe("/order")
            let message = client.consume(sid)
            let position = (message.queueIndex, message.segmentedIndex, message.segmentedOffset)

            // 第一次 ack 被服务端拒绝：异常上抛，映射必须保留
            var code = -1i64
            try {
                client.ack(sid, position[0], position[1], position[2])
            } catch (e: MQServiceException) {
                code = e.code
            }
            @Assert(code == MQErrorCode.INTERNAL)

            // 重试命中同一条映射：成功，映射删除，空节点没收到 ACK
            client.ack(sid, position[0], position[1], position[2])
            @Assert(countOf(empty, "ACK") == 0)
            @Assert(countOf(owner, "ACK") == 2)

            // 映射已删除：第三次 ack 走广播路径，两个 owner 都收到
            client.ack(sid, position[0], position[1], position[2])
            @Assert(countOf(empty, "ACK") == 1)
            @Assert(countOf(owner, "ACK") == 3)
            client.close()
        } finally {
            empty.close()
            owner.close()
        }
    }

    /** tags 顺序是业务语义：10 个 tag 发布后按原顺序还原（R1-G15）。 */
    @TestCase
    public func publishKeepsTenTagsInOrder(): Unit {
        let stub = MQStubServer(ok).start()
        try {
            let client = MQClient([stub.address()])
            let tags = Array<String>(10) {i => "tag-${i}"}
            client.publish("/order", 1i64, tags: tags)
            let record = MQProtocol.asRecord(stub.received()[0]).getOrThrow()
            @Assert(MQMessageRecord.decode(record).getOrThrow().tags == tags)
            client.close()
        } finally {
            stub.close()
        }
    }

    /** 订阅 owner 汇总只含接受者：NOT_OWNER 节点不参与 consume/ack（R1-G17）。 */
    @TestCase
    public func subscribeOwnersOnlyContainAcceptors(): Unit {
        let acceptor = MQStubServer({buffer, request =>
            match (request.command) {
                case CONSUME(_) => Some(MQProtocol.respond<MQConsumeResult>(request, stubMessage("/order", 5, 0)))
                case _ => Some(MQProtocol.respond<MQResult>(request, MQResult(0, "ok")))
            }
        }).start()
        let bystander = MQStubServer({buffer, request => okBut(buffer, request, MQErrorCode.NOT_OWNER)}).start()
        try {
            let client = MQClient([bystander.address(), acceptor.address()])
            let sid = client.subscribe("/order")
            let message = client.consume(sid)
            client.ack(sid, message.queueIndex, message.segmentedIndex, message.segmentedOffset)
            @Assert(countOf(bystander, "CONSUME") == 0)
            @Assert(countOf(bystander, "ACK") == 0)
            @Assert(countOf(acceptor, "CONSUME") == 1)
            @Assert(countOf(acceptor, "ACK") == 1)
            client.close()
        } finally {
            acceptor.close()
            bystander.close()
        }
    }

    /** 对象 BODY 端到端：publish → consume → get<T>() 字段相等，跨类型读为 None（R1-G18）。 */
    @TestCase
    public func objectBodyRoundTripsThroughPublishAndConsume(): Unit {
        let published = ConcurrentHashMap<String, Array<Byte>>()
        let stub = MQStubServer({buffer, request =>
            match (request.command) {
                case PUBLISH(_) =>
                    published.add("record", MQProtocol.asRecord(request).getOrThrow())
                    Some(MQProtocol.respond<MQResult>(request, MQResult(0, "ok")))
                case CONSUME(_) =>
                    let record = published.get("record").getOrThrow()
                    Some(MQProtocol.respond<MQConsumeResult>(request, MQConsumeResult(0, 1, 0, record)))
                case _ => Some(MQProtocol.respond<MQResult>(request, MQResult(0, "ok")))
            }
        }).start()
        try {
            let client = MQClient([stub.address()])
            client.publish("/order", OrderBody("book", 42))
            let sid = client.subscribe("/order")
            let message = client.consume(sid)
            let body = message.get<OrderBody>().getOrThrow()
            @Assert(body.name == "book")
            @Assert(body.amount == 42)
            @Assert(message.get<String>().isNone())
            client.close()
        } finally {
            stub.close()
        }
    }

    /** 全部 owner 不可达的消费失败日志要带订阅 id 与主题（R1-G2）。 */
    @TestCase
    public func consumeFailureLogsSubscriptionAndTopic(): Unit {
        CapturingAppender.install()
        let stub = MQStubServer(ok).start()
        let client = MQClient([stub.address()])
        let sid = client.subscribe("/order")
        stub.close()
        try {
            try {
                client.consume(sid)
            } catch (_: MQConnectionException) {
                ()
            }
            @Assert(CapturingAppender.waitFor([sid, "/order", "unreachable"]))
        } finally {
            client.close()
        }
    }
}

/** 端到端对象 BODY 的载荷类型。 */
@DataAssist[props fields]
public class OrderBody {
    private var name: String = ''
    private var amount: Int64 = 0

    public init() {}

    public init(name: String, amount: Int64) {
        this.name = name
        this.amount = amount
    }
}

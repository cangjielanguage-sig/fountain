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
package fountain::f_mq.test

// 只依赖门面，验证业务侧 `import fountain::f_mq.*` 即可用
import fountain::f_mq.*
import fountain::f_data.*
import fountain::f_util.UUID
import std.unittest.*
import std.unittest.testmacro.*

@Test
class FacadeTest {
    @TestCase
    public func facadeExposesDocumentedApi(): Unit {
        let meta = MQTopicMeta("/order", 2)
        @Assert(meta.topic == "/order")
        @Assert(meta.queueNum == 2)

        let group = MQSubscribeGroupMeta("/order", "g")
        @Assert(group.subscribeGroup == "g")

        let assignment = MQTopicAssignment("/order", 2, 0, [0, 1])
        @Assert(assignment.owner(1) == Some(1))

        let message = MQMessage("/order", ["a"], Some(DataAny(1i64.toData())), 0, 1, 0)
        @Assert(message.get<Int64>() == Some(1))

        let error = MQServiceException(MQErrorCode.TOPIC_NOT_EXIST, "missing")
        @Assert(error.code == 1)
        @Assert(MQErrorCode.messageOf(1) == "topic does not exist")

        let sid = UUID.random().toString()
        @Assert(UUID.tryParse(sid).isSome())
    }

    @TestCase
    public func facadeClientLifecycleWithoutServer(): Unit {
        // 构造不建连；关闭幂等
        let client = MQClient(["127.0.0.1:1"])
        @Assert(!client.isClosed())
        client.close()
        @Assert(client.isClosed())
        client.close()

        var threw = false
        try {
            client.publish("/t", 1i64)
        } catch (_: MQConnectionException) {
            threw = true
        }
        @Assert(threw)
    }
}

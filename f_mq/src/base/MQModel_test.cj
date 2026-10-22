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
package fountain::f_mq.base

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.*
import fountain::f_data.macros.*
import fountain::f_codec.default.DefaultCodec
import fountain::f_io.ByteBuffer
import fountain::f_mq.base.model.*

@DataAssist[props fields]
public class TestOrderBody {
    private var id: Int64 = 0
    private var title: String = ''
    private var enabled: Bool = false

    public init() {}

    public init(id: Int64, title: String, enabled: Bool) {
        this.id = id
        this.title = title
        this.enabled = enabled
    }
}

@Test
class MQModelTest {
    private static func roundtrip<T>(value: T): ?T where T <: DataFields<T> {
        let codec = DefaultCodec()
        var bytes: Array<Byte> = []
        try {
            codec.encode(value.toData())
            bytes = codec.finish().asBytes().getOrThrow()
        } finally {
            codec.release()
        }
        let decoder = DefaultCodec()
        var result: ?T = None<T>
        try {
            result = decoder.decode<T>(ByteBuffer(bytes))
        } finally {
            decoder.release()
        }
        result
    }

    @TestCase
    public func topicMetaRoundtrip(): Unit {
        let value = MQTopicMeta("/order/create", 4)
        @Assert(value.topic == "/order/create")
        @Assert(value.queueNum == 4)
        let back = roundtrip<MQTopicMeta>(value).getOrThrow()
        @Assert(back.topic == value.topic)
        @Assert(back.queueNum == value.queueNum)
    }

    @TestCase
    public func subscribeGroupMetaRoundtrip(): Unit {
        let value = MQSubscribeGroupMeta("/order", "")
        let back = roundtrip<MQSubscribeGroupMeta>(value).getOrThrow()
        @Assert(back.topic == "/order")
        @Assert(back.subscribeGroup.isEmpty())
    }

    @TestCase
    public func messageGetSupportsScalarsAndObjects(): Unit {
        let scalar = MQMessage("/t", ["a"], Some(DataAny(42i64.toData())), 0, 7, 128)
        @Assert(scalar.get<Int64>() == Some(42))

        let obj = TestOrderBody(9, "book", true)
        let message = MQMessage("/t", [], Some(DataAny(obj.toData())), 0, 1, 2)
        let got = message.get<TestOrderBody>().getOrThrow()
        @Assert(got.id == 9)
        @Assert(got.title == "book")
        @Assert(got.enabled)
        // 对象载荷不能当标量读出
        @Assert(message.get<Int64>().isNone())

        let empty = MQMessage("/t", [], None, 0, 0, 0)
        @Assert(empty.get<Int64>().isNone())

        @Assert(scalar.segmentedIndex == 7)
        @Assert(scalar.segmentedOffset == 128)
        @Assert(scalar.tags == ["a"])
    }

    /** 空 BODY / 异类对象 BODY / 标量 BODY 都不得解出「字段全默认的对象」（A04）。 */
    @TestCase
    public func messageGetRejectsEmptyAndMismatchedBody(): Unit {
        let noneBody = MQMessage("/t", [], Some(DataAny(DataNone.INSTANCE)), 0, 0, 0)
        @Assert(noneBody.get<TestOrderBody>().isNone())

        let otherObject = MQMessage("/t", [], Some(DataAny(MQTopicMeta("/x", 1).toData())), 0, 0, 0)
        @Assert(otherObject.get<TestOrderBody>().isNone())

        let scalar = MQMessage("/t", [], Some(DataAny(42i64.toData())), 0, 0, 0)
        @Assert(scalar.get<TestOrderBody>().isNone())

        let collection = MQMessage("/t", [], Some(DataAny([1i64, 2].toData())), 0, 0, 0)
        @Assert(collection.get<TestOrderBody>().isNone())

        // 正例：同类型对象照常解出
        let ok = MQMessage("/t", [], Some(DataAny(TestOrderBody(5, "ok", false).toData())), 0, 0, 0)
        let got = ok.get<TestOrderBody>().getOrThrow()
        @Assert(got.id == 5)
        @Assert(got.title == "ok")
    }

    @TestCase
    public func messageRoundtripKeepsBodyAndPosition(): Unit {
        let message = MQMessage("/t", ["x", "y"], Some(DataAny("hello".toData())), 2, 3, 64)
        let back = roundtrip<MQMessage>(message).getOrThrow()
        @Assert(back.topic == "/t")
        @Assert(back.tags == ["x", "y"])
        @Assert(back.queueIndex == 2)
        @Assert(back.segmentedIndex == 3)
        @Assert(back.segmentedOffset == 64)
        @Assert(back.get<String>() == Some("hello"))
    }

    @TestCase
    public func messageContentToMessage(): Unit {
        let content = MQMessageContent("/t", ["a"], "mid", DataAny(7i64.toData()))
        let message = content.toMessage(4, 11, 22)
        @Assert(message.topic == "/t")
        @Assert(message.tags == ["a"])
        @Assert(message.queueIndex == 4)
        @Assert(message.segmentedIndex == 11)
        @Assert(message.segmentedOffset == 22)
        @Assert(message.get<Int64>() == Some(7))
    }
}

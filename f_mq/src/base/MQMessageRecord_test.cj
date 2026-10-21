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
import std.collection.{ArrayList, HashMap, HashSet, TreeMap, TreeSet}
import std.fs.*
import std.math.numeric.Decimal
import std.time.DateTime
import fountain::f_data.*
import fountain::f_data.macros.*
import fountain::f_codec.default.DefaultCodec
import fountain::f_io.ByteBuffer

@DataAssist[props fields]
public class TestRecordBody {
    private var name: String = ''
    private var value: Int64 = 0

    public init() {}

    public init(name: String, value: Int64) {
        this.name = name
        this.value = value
    }
}

@Test
class MQMessageRecordTest {
    private static func encode(topic: String, tags: Array<String>, mid: String, body: Data): Array<Byte> {
        MQMessageRecord.encode(topic, tags, mid, body)
    }

    @TestCase
    public func fullRoundtripKeepsAllSegments(): Unit {
        let record = encode("/order", ["a", "b"], "mid-1", TestRecordBody("book", 9).toData())
        let content = MQMessageRecord.decode(record).getOrThrow()
        @Assert(content.topic == "/order")
        @Assert(content.tags == ["a", "b"])
        @Assert(content.messageId == "mid-1")
        let body = convert<TestRecordBody>(content.body.data).getOrThrow()
        @Assert(body.name == "book")
        @Assert(body.value == 9)
    }

    @TestCase
    public func scalarAndCollectionBodiesRoundtrip(): Unit {
        // 标量
        let intRecord = encode("/t", [], "m", 42i64.toData())
        @Assert(convert<Int64>(MQMessageRecord.body(intRecord).getOrThrow().data) == Some(42))

        // String
        let strRecord = encode("/t", [], "m", "hello".toData())
        @Assert(convert<String>(MQMessageRecord.body(strRecord).getOrThrow().data) == Some("hello"))

        // Decimal / DateTime / Duration
        let decimal = Decimal.parse("3.14")
        let decRecord = encode("/t", [], "m", decimal.toData())
        @Assert(convert<Decimal>(MQMessageRecord.body(decRecord).getOrThrow().data) == Some(decimal))

        let time = DateTime.now()
        let timeRecord = encode("/t", [], "m", time.toData())
        @Assert(convert<DateTime>(MQMessageRecord.body(timeRecord).getOrThrow().data) == Some(time))

        let duration = Duration.second * 3
        let durRecord = encode("/t", [], "m", duration.toData())
        @Assert(convert<Duration>(MQMessageRecord.body(durRecord).getOrThrow().data) == Some(duration))

        // 集合
        let array = ["x", "y"]
        let arrRecord = encode("/t", [], "m", array.toData())
        @Assert(convert<Array<String>>(MQMessageRecord.body(arrRecord).getOrThrow().data) == Some(array))

        let list = ArrayList<String>()
        list.add("p")
        list.add("q")
        let listRecord = encode("/t", [], "m", list.toData())
        @Assert(convert<ArrayList<String>>(MQMessageRecord.body(listRecord).getOrThrow().data) == Some(list))

        let set = HashSet<String>()
        set.add("s1")
        let setRecord = encode("/t", [], "m", set.toData())
        @Assert(convert<HashSet<String>>(MQMessageRecord.body(setRecord).getOrThrow().data) == Some(set))

        let map = TreeMap<String, Int64>()
        map.add("k", 1)
        let mapRecord = encode("/t", [], "m", map.toData())
        @Assert(convert<TreeMap<String, Int64>>(MQMessageRecord.body(mapRecord).getOrThrow().data) == Some(map))
    }

    @TestCase
    public func containerBodiesRoundtrip(): Unit {
        // TreeSet
        let treeSet = TreeSet<Int64>()
        treeSet.add(2)
        treeSet.add(1)
        treeSet.add(3)
        let setRecord = encode("/t", [], "m", treeSet.toData())
        @Assert(convert<TreeSet<Int64>>(MQMessageRecord.body(setRecord).getOrThrow().data) == Some(treeSet))

        // HashMap
        let hashMap = HashMap<String, Int64>()
        hashMap.add("age", 40)
        hashMap.add("count", 3)
        let hashRecord = encode("/t", [], "m", hashMap.toData())
        @Assert(convert<HashMap<String, Int64>>(MQMessageRecord.body(hashRecord).getOrThrow().data) == Some(hashMap))

        // Array<Int64>（非字符串元素）
        let intArray: Array<Int64> = [10, 20, 30]
        let intArrayRecord = encode("/t", [], "m", intArray.toData())
        @Assert(convert<Array<Int64>>(MQMessageRecord.body(intArrayRecord).getOrThrow().data) == Some(intArray))
    }

    @TestCase
    public func emptyContainerBodiesRoundtrip(): Unit {
        let emptySet = TreeSet<Int64>()
        let setRecord = encode("/t", [], "m", emptySet.toData())
        @Assert(convert<TreeSet<Int64>>(MQMessageRecord.body(setRecord).getOrThrow().data).getOrThrow().isEmpty())

        let emptyMap = HashMap<String, Int64>()
        let mapRecord = encode("/t", [], "m", emptyMap.toData())
        @Assert(convert<HashMap<String, Int64>>(MQMessageRecord.body(mapRecord).getOrThrow().data).getOrThrow().isEmpty())

        let emptyArray = Array<Int64>()
        let arrayRecord = encode("/t", [], "m", emptyArray.toData())
        @Assert(convert<Array<Int64>>(MQMessageRecord.body(arrayRecord).getOrThrow().data).getOrThrow().size == 0)
    }

    @TestCase
    public func publishTimeParsesStandardMessageId(): Unit {
        let record = encode("/t", [], "1_2_3_20261018183000123456789", 1i64.toData())
        let time = MQMessageRecord.publishTime(record).getOrThrow()
        @Assert(time.format("yyyyMMddHHmmssSSS") == "20261018183000123456789")
    }

    /** 时间戳文本按 UTC 解释，往返后与原始绝对时刻一致（A02）。 */
    @TestCase
    public func publishTimeRoundTripsAcrossTimeZones(): Unit {
        let moment = DateTime.ofUTC(year: 2026, month: 8, dayOfMonth: 21, hour: 10, minute: 30,
            second: 15, nanosecond: 123000000)
        let stamp = moment.format("yyyyMMddHHmmssSSS")
        let record = encode("/t", [], "7_8_9_${stamp}", 1i64.toData())
        let parsed = MQMessageRecord.publishTime(record).getOrThrow()
        @Assert(parsed.toUnixTimeStamp() == moment.toUnixTimeStamp())
    }

    @TestCase
    public func publishTimeRejectsNonStandardMessageId(): Unit {
        @Assert(MQMessageRecord.publishTime(encode("/t", [], "mid-1", 1i64.toData())).isNone())
        @Assert(MQMessageRecord.publishTime(encode("/t", [], "a_b_2026", 1i64.toData())).isNone())
    }

    @TestCase
    public func emptyTagsStayEmpty(): Unit {
        let record = encode("/t", [], "m", 1i64.toData())
        let tags = MQMessageRecord.tags(record).getOrThrow()
        @Assert(tags.size == 0)
        @Assert(MQMessageRecord.decode(record).getOrThrow().tags.size == 0)
    }

    @TestCase
    public func perSegmentDecodersAgree(): Unit {
        let record = encode("/a/b", ["t1", "t2"], "mid-xyz", 7i64.toData())
        @Assert(MQMessageRecord.topic(record) == Some("/a/b"))
        @Assert(MQMessageRecord.tags(record) == Some(["t1", "t2"]))
        @Assert(MQMessageRecord.messageId(record) == Some("mid-xyz"))
        @Assert(convert<Int64>(MQMessageRecord.body(record).getOrThrow().data) == Some(7))
    }

    @TestCase
    public func emptyBodyStaysNone(): Unit {
        let record = encode("/t", [], "m", DataNone.INSTANCE)
        let content = MQMessageRecord.decode(record).getOrThrow()
        match (content.body.data) {
            case _: DataNone => @Assert(true)
            case _ => @Assert(false)
        }
    }

    @TestCase
    public func brokenRecordsReturnNone(): Unit {
        let record = encode("/t", ["a"], "m", 1i64.toData())

        // 空记录
        @Assert(MQMessageRecord.decode([]).isNone())
        @Assert(MQMessageRecord.topic([]).isNone())

        // 截断
        for (cut in 1..record.size) {
            @Assert(MQMessageRecord.decode(record[0..cut]).isNone())
        }

        // 多余字节
        let extra = Array<Byte>(record.size + 1, repeat: 0u8)
        record.copyTo(extra, 0, 0, record.size)
        @Assert(MQMessageRecord.decode(extra).isNone())
    }

    @TestCase
    public func prefixDecodersIgnoreTrailingBytes(): Unit {
        let record = encode("/t", ["a"], "m", 5i64.toData())
        let extra = Array<Byte>(record.size + 1, repeat: 0u8)
        record.copyTo(extra, 0, 0, record.size)
        @Assert(MQMessageRecord.topic(extra) == Some("/t"))
        @Assert(MQMessageRecord.tags(extra) == Some(["a"]))
        @Assert(MQMessageRecord.messageId(extra) == Some("m"))
        @Assert(convert<Int64>(MQMessageRecord.body(extra).getOrThrow().data) == Some(5))
        // 完整解码要求恰好用尽
        @Assert(MQMessageRecord.decode(extra).isNone())
    }

    @TestCase
    public func messageIdMatchesInput(): Unit {
        let record = encode("/t", [], "p_1_2_3", 1i64.toData())
        @Assert(MQMessageRecord.decode(record).getOrThrow().messageId == "p_1_2_3")
    }

    @TestCase
    public func mqBytesReadsByteBlock(): Unit {
        let bytes: Array<Byte> = [1u8, 2u8, 3u8]
        @Assert(MQBytes.fromData(bytes.toData()) == Some(bytes))
        // 非字节载荷返回 None，而不是空数组
        @Assert(MQBytes.fromData(DataNone.INSTANCE).isNone())
        @Assert(MQBytes.fromData(TestRecordBody("a", 1).toData()).isNone())
    }

    @TestCase
    public func mqBytesRestoresLargeTempFilePayload(): Unit {
        let big = Array<Byte>(16 * 1024, repeat: 0u8)
        for (i in 0..big.size) {
            big[i] = UInt8(i % 251)
        }
        let codec = DefaultCodec()
        var payloadBytes: Array<Byte> = []
        try {
            codec.encode(big)
            payloadBytes = codec.finish().asBytes().getOrThrow()
        } finally {
            codec.release()
        }
        let decoder = DefaultCodec()
        var data: Data = DataNone.INSTANCE
        try {
            data = decoder.decodeData(ByteBuffer(payloadBytes))
        } finally {
            decoder.release()
        }
        // > 4096 的记录应走临时文件形态
        let temp = match (data) {
            case d: DataInputStream =>
                match (d.data) {
                    case f: File => Some(f)
                    case _ => None<File>
                }
            case _ => None<File>
        }
        @Assert(temp.isSome())
        let path = temp.getOrThrow().info.path.toString()
        let restored = MQBytes.fromData(data).getOrThrow()
        @Assert(restored == big)
        // 临时文件与父目录都被清理
        @Assert(!exists(path))
    }

    @TestCase
    public func encoderResourcesAreReturned(): Unit {
        // 大量编码不应耗尽池资源
        for (i in 0..500) {
            let record = encode("/t", ["a"], "m${i}", i.toData())
            @Assert(MQMessageRecord.decode(record).isSome())
        }
    }
}

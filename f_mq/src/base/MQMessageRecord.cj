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

import std.collection.ArrayList
import std.fs.*
import std.io.SeekPosition
import std.time.*
import fountain::f_data.*
import fountain::f_codec.default.DefaultCodec
import fountain::f_io.ByteBuffer
import fountain::f_mq.base.model.MQMessageContent
import fountain::f_mq.base.payload.MQBlob

/**
 * 一条消息记录的编解码。
 *
 * 布局：`codec(TOPIC:String) ‖ codec(TAGS:Array<String>) ‖ codec(MESSAGE_ID:String) ‖ codec(BODY)`。
 * 四段各自独立编码、连续排列、无额外长度前缀；接收侧用同一个 `DefaultCodec` 逐段解码。
 *
 * 完整性判定必须同时满足「四段都解出」与「恰好消费完所有字节」：`ByteBuffer.read`
 * 读不满时会 `clear()` 把偏移归零，不能依赖「读不满自动返回空」。
 */
public class MQMessageRecord {
    /** 逐段编码。调用方负责保证 `messageId` 与帧 id 取同一个值。 */
    public static func encode<T>(topic: String, tags: Array<String>, messageId: String, body: T): Array<Byte>
        where T <: ToData {
        let codec = DefaultCodec()
        try {
            codec.encode(topic).encode(tags).encode(messageId).encode(body.toData())
            match (codec.finish().asBytes()) {
                case Some(bytes) => bytes
                case None => throw IllegalArgumentException("MQMessageRecord.encode: codec produced no bytes")
            }
        } finally {
            codec.release()
        }
    }

    /** 完整解码；截断 / 多余字节 / 空记录都返回 `None`。 */
    public static func decode(record: Array<Byte>): ?MQMessageContent {
        let values = decodeValues(record, 4, exact: true)
        match (values) {
            case None => None<MQMessageContent>
            case Some(v) =>
                match (convert<String>(v[0])) {
                    case None => None<MQMessageContent>
                    case Some(topic) =>
                        match (convert<Array<String>>(v[1])) {
                            case None => None<MQMessageContent>
                            case Some(tags) =>
                                match (convert<String>(v[2])) {
                                    case None => None<MQMessageContent>
                                    case Some(messageId) => Some(
                                        MQMessageContent(topic, tags, messageId, DataAny(v[3])))
                                }
                        }
                }
        }
    }

    /** 只解 TOPIC（服务端路由用，不碰后续段）。 */
    public static func topic(record: Array<Byte>): ?String {
        match (valueAt(record, 0)) {
            case None => None<String>
            case Some(d) => convert<String>(d)
        }
    }

    /** 只解 TAGS（服务端 tags 匹配用）。 */
    public static func tags(record: Array<Byte>): ?Array<String> {
        match (valueAt(record, 1)) {
            case None => None<Array<String>>
            case Some(d) => convert<Array<String>>(d)
        }
    }

    /** 只解 MESSAGE_ID（排障 / 日志用）。 */
    public static func messageId(record: Array<Byte>): ?String {
        match (valueAt(record, 2)) {
            case None => None<String>
            case Some(d) => convert<String>(d)
        }
    }

    /**
     * 解析记录发布时间。
     *
     * messageId 形如 `pid_tid_hostId_<yyyyMMddHHmmss + 9 位纳秒>`（UTC）；只接受末尾 23 位数字。
     * 非标准 ID（例如测试里的 `mid-1`）返回 `None`，由调用方决定兜底策略。
     */
    public static func publishTime(record: Array<Byte>): ?DateTime {
        let idOpt = messageId(record)
        if (idOpt.isNone()) {
            return None<DateTime>
        }
        let parts = idOpt.getOrThrow().split("_")
        if (parts.size == 0) {
            return None<DateTime>
        }
        let stamp = parts[parts.size - 1]
        if (stamp.size != 23) {
            return None<DateTime>
        }
        for (c in stamp.toRuneArray()) {
            if (c < r'0' || c > r'9') {
                return None<DateTime>
            }
        }
        try {
            // 直接按字段构造 UTC 实例：不经过「按本地时区解析再补偿偏移」，
            // 进程时区、夏令时都不会影响结果（A02）
            Some(DateTime.ofUTC(
                year: Int64.parse(stamp[0..4]),
                month: Int64.parse(stamp[4..6]),
                dayOfMonth: Int64.parse(stamp[6..8]),
                hour: Int64.parse(stamp[8..10]),
                minute: Int64.parse(stamp[10..12]),
                second: Int64.parse(stamp[12..14]),
                nanosecond: Int64.parse(stamp[14..23])))
        } catch (_: Exception) {
            None<DateTime>
        }
    }

    /** 只解 BODY（服务端 filter 求值用；BODY 之后的字节不计入）。 */
    public static func body(record: Array<Byte>): ?DataAny {
        match (valueAt(record, 3)) {
            case None => None<DataAny>
            case Some(d) => Some(DataAny(d))
        }
    }

    /**
     * 解出从 0 开始的第 `index` 个值；截断或无法解码时返回 `None`。
     *
     * 每次调用都会从记录头顺序解码（值自描述，无法随机访问），用于前缀查询足够轻量。
     */
    private static func valueAt(record: Array<Byte>, index: Int64): ?Data {
        match (decodeValues(record, index + 1, exact: false)) {
            case None => None<Data>
            case Some(v) => Some(v[index])
        }
    }

    /**
     * 顺序解码 `count` 个值。
     *
     * `exact = true` 时要求恰好消费完整个记录（用于完整解码与损坏判定）。
     */
    private static func decodeValues(record: Array<Byte>, count: Int64, exact!: Bool): ?Array<Data> {
        if (record.size == 0) {
            return None<Array<Data>>
        }
        let codec = DefaultCodec()
        try {
            let buffer = ByteBuffer(record)
            let values = ArrayList<Data>()
            for (_ in 0..count) {
                values.add(codec.decodeData(buffer))
            }
            if (exact && buffer.readOffset != record.size) {
                return None<Array<Data>>
            }
            Some(values.unsafeData())
        } catch (_: Exception) {
            None<Array<Data>>
        } finally {
            codec.release()
        }
    }
}

/**
 * 把帧载荷还原成记录字节。
 *
 * `DefaultCodec` 对大载荷（> 4096 字节）会返回「临时文件」形态；本类同时支持两种形态，
 * 并在读回后删除临时文件与父目录。无法识别为字节序列时返回 `None` —— 绝不返回空数组，
 * 否则大消息会被误判成「没有消息」。
 */
public class MQBytes {
    /**
     * 与 `MQBlob` 共用同一实现：字节块 / 大载荷临时文件 / `DataAny` 包装都走一条路径，
     * 无法识别时返回 `None`，绝不返回空数组。
     */
    public static func fromData(data: Data): ?Array<Byte> {
        // 空载荷不是「空记录」：调用方靠 `None` 区分「没有载荷」与「零字节记录」
        if (let _: DataNone <- data) {
            return None<Array<Byte>>
        }
        match (MQBlob.tryFromData(data, SILENCE)) {
            case x: ?MQBlob =>
                match (x) {
                    case Some(blob) => Some(blob.copyBytes())
                    case _ => None<Array<Byte>>
                }
            case b: MQBlob => Some(b.copyBytes())
            case _ => None<Array<Byte>>
        }
    }
}

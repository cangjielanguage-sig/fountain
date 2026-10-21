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

import fountain::f_data.*
import fountain::f_codec.default.DefaultCodec
import fountain::f_io.ByteBuffer
import fountain::f_mq.base.model.*
import fountain::f_mq.base.payload.*
import fountain::f_protocol.default.*

/**
 * MQ 协议层：命令构造 / 响应构造 / 载荷解析。
 *
 * 不新增 `f_protocol` 命令号：同一命令的不同用途一律靠载荷的运行时类型区分。
 */
public class MQProtocol {
    // ===== 请求构造 =====

    /** 发布记录。`id` 为空时新建帧 id（此时记录中的 MESSAGE_ID 与帧 id 不保证一致）。 */
    public static func publish(record: Array<Byte>, id!: ?MessageID = None): Message {
        match (id) {
            case Some(mid) => Message.build<Array<Byte>>(Command.PUBLISH(0), mid, Some(record))
            case None => Message.publish<Array<Byte>>(dup: false, qos: QoS.AtMostOnce, retain: false, data: record)
        }
    }

    /** 备份推送：`PUBLISH` + `MQInternalMessage{kind = backup}`。 */
    public static func publishBackup(payload: MQBackupPayload): Message {
        let envelope = MQInternalMessage(MQInternalKind.BACKUP, encodePayload<MQBackupPayload>(payload))
        Message.publish<MQInternalMessage>(dup: false, qos: QoS.AtMostOnce, retain: false, data: envelope)
    }

    public static func subscribe(payload: MQSubscribePayload): Message {
        Message.subscribe<MQSubscribePayload>(data: payload)
    }

    public static func unsubscribe(payload: MQUnsubscribePayload): Message {
        Message.unsubscribe<MQUnsubscribePayload>(MessageID(), data: payload)
    }

    public static func consume(payload: MQConsumePayload): Message {
        Message.consume<MQConsumePayload>(once: true, qos: QoS.AtMostOnce, data: payload)
    }

    public static func ack(payload: MQAckPayload): Message {
        Message.ack<MQAckPayload>(MessageID(), data: payload)
    }

    public static func registerTopic(meta: MQTopicMeta): Message {
        Message.register<MQTopicMeta>(data: meta)
    }

    public static func registerGroup(meta: MQSubscribeGroupMeta): Message {
        Message.register<MQSubscribeGroupMeta>(data: meta)
    }

    public static func deregister(payload: MQDeregisterPayload): Message {
        Message.deregister<MQDeregisterPayload>(data: payload)
    }

    /** 元数据同步请求：`REGISTER` + `MQInternalMessage{kind = metaSync}`。 */
    public static func metaSync(request: MQMetaSyncRequest): Message {
        let envelope = MQInternalMessage(MQInternalKind.META_SYNC, encodePayload<MQMetaSyncRequest>(request))
        Message.register<MQInternalMessage>(data: envelope)
    }

    /** 元数据变更广播：`REGISTER` + `MQInternalMessage{kind = metaSync}`，子载荷为 `MQTopicAssignment`。 */
    public static func metaSync(assignment: MQTopicAssignment): Message {
        let envelope = MQInternalMessage(MQInternalKind.META_SYNC, encodePayload<MQTopicAssignment>(assignment))
        Message.register<MQInternalMessage>(data: envelope)
    }

    /** 订阅组变更广播：`REGISTER` + `MQInternalMessage{kind = metaSync}`，子载荷为 `MQSubscribeGroupMeta`。 */
    public static func metaSync(meta: MQSubscribeGroupMeta): Message {
        let envelope = MQInternalMessage(MQInternalKind.META_SYNC, encodePayload<MQSubscribeGroupMeta>(meta))
        Message.register<MQInternalMessage>(data: envelope)
    }

    /** 删除广播：`DEREGISTER` + `MQInternalMessage{kind = metaSync}`，子载荷为 `MQDeregisterPayload`。 */
    public static func metaSync(payload: MQDeregisterPayload): Message {
        let envelope = MQInternalMessage(MQInternalKind.META_SYNC, encodePayload<MQDeregisterPayload>(payload))
        Message.deregister<MQInternalMessage>(data: envelope)
    }

    /** 墓碑广播：`DEREGISTER` + `MQInternalMessage{kind = metaSync}`，子载荷为 `MQMetaTombstone`。 */
    public static func metaSync(tombstone: MQMetaTombstone): Message {
        let envelope = MQInternalMessage(MQInternalKind.META_SYNC, encodePayload<MQMetaTombstone>(tombstone))
        Message.deregister<MQInternalMessage>(data: envelope)
    }

    /** 指标查询：`REGISTER` + `MQInternalMessage{kind = stats}`，子载荷为 topic 字符串。 */
    public static func stats(topic: String): Message {
        let envelope = MQInternalMessage(MQInternalKind.STATS, encodePayload<String>(topic))
        Message.register<MQInternalMessage>(data: envelope)
    }

    // ===== 响应构造 =====

    public static func respond<T>(request: Message, data: T): Message where T <: ToData {
        Message.resp<T>(request.id, qos: QoS.AtMostOnce, ack: false, data: data)
    }

    public static func respondEmpty(request: Message): Message {
        Message.resp<DataNone>(request.id, qos: QoS.AtMostOnce, ack: false, data: DataNone.INSTANCE)
    }

    public static func fail(request: Message, code: Int64, message: String): Message {
        Message.error<MQResult>(request.id, data: MQResult(code, message))
    }

    // ===== 解析 =====

    /** 按载荷运行时类型分派（服务端用）。 */
    public static func kindOf(message: Message): MQPayloadKind {
        match (message.data) {
            case _: DataCollection<Array<Byte>, Byte> => MQPayloadKind.Record
            case _: DataInputStream => MQPayloadKind.Record
            case _: DataNone => MQPayloadKind.Empty
            case o: SimpleDataObject =>
                let name = o.typeInfo.qualifiedName
                if (name == TypeInfo.of<MQTopicMeta>().qualifiedName) {
                    MQPayloadKind.TopicMeta
                } else if (name == TypeInfo.of<MQSubscribeGroupMeta>().qualifiedName) {
                    MQPayloadKind.GroupMeta
                } else if (name == TypeInfo.of<MQInternalMessage>().qualifiedName) {
                    MQPayloadKind.Internal
                } else {
                    MQPayloadKind.Unknown
                }
            case _ => MQPayloadKind.Unknown
        }
    }

    /** 记录字节（兼容字节块与大载荷临时文件两种形态）。 */
    public static func asRecord(message: Message): ?Array<Byte> {
        MQBytes.fromData(message.data)
    }

    /** 把载荷转换为对象；类型不匹配返回 `None`，不抛异常。 */
    public static func asPayload<T>(message: Message): ?T where T <: DataFields<T> {
        // 先按运行时类型精确匹配：`convert` 的 SILENCE 语义会把「别的对象」宽松转成默认对象，
        // 必须在这里挡掉，否则服务端会把一种载荷误当成另一种。
        match (message.data) {
            case o: SimpleDataObject =>
                if (o.typeInfo.qualifiedName != TypeInfo.of<T>().qualifiedName) {
                    return None<T>
                }
            case _ => return None<T>
        }
        try {
            convert<T>(message.data, flag: SILENCE)
        } catch (_: Exception) {
            None<T>
        }
    }

    public static func asInternal(message: Message): ?MQInternalMessage {
        match (message.data) {
            case o: SimpleDataObject =>
                if (o.typeInfo.qualifiedName == TypeInfo.of<MQInternalMessage>().qualifiedName) {
                    asPayload<MQInternalMessage>(message)
                } else {
                    None<MQInternalMessage>
                }
            case _ => None<MQInternalMessage>
        }
    }

    /** RESP 载荷的通用结果；空载荷视为成功。 */
    public static func asResult(message: Message): MQResult {
        match (message.data) {
            case _: DataNone => MQResult(0, "ok")
            case _ =>
                match (asPayload<MQResult>(message)) {
                    case Some(r) => r
                    case None => MQResult(MQErrorCode.INTERNAL, "unrecognized result payload")
                }
        }
    }

    public static func asConsumeResult(message: Message): ?MQConsumeResult {
        asPayload<MQConsumeResult>(message)
    }

    // ===== 内部子载荷编解码 =====

    /** `T` 是否是「对象型」载荷（`@DataAssist` 类），而不是标量/集合。 */
    private static func isObjectPayload<T>(): Bool where T <: FromToData {
        try {
            match (T.tryFromData(DataNone.INSTANCE)) {
                case _: SimpleDataObject => true
                case _ => false
            }
        } catch (_: Exception) {
            false
        }
    }

    /** 把任意自描述值编码为字节（内部消息的子载荷）。 */
    public static func encodePayload<T>(value: T): Array<Byte> where T <: ToData {
        let codec = DefaultCodec()
        try {
            codec.encode(value.toData())
            match (codec.finish().asBytes()) {
                case Some(bytes) => bytes
                case None => throw IllegalArgumentException("MQProtocol.encodePayload: codec produced no bytes")
            }
        } finally {
            codec.release()
        }
    }

    /** 从 `MQBlob` 解出自描述值；损坏返回 `None`。 */
    public static func decodePayload<T>(blob: MQBlob): ?T where T <: FromToData {
        decodePayload<T>(blob.copyBytes())
    }

    /** 从字节解出自描述值；损坏返回 `None`。 */
    public static func decodePayload<T>(bytes: Array<Byte>): ?T where T <: FromToData {
        if (bytes.size == 0) {
            return None<T>
        }
        let codec = DefaultCodec()
        try {
            let data = codec.decodeData(ByteBuffer(bytes))
            // 只按运行时类型精确匹配：codec 的 decode 会按编码里的类型创建对象，
            // 但 `T.tryFromData` 的 SILENCE 语义会把「别的类型」宽松转成默认 T ——
            // 这正是「标量载荷解出字段全默认对象」的来源，必须在转换前挡掉。
            match (data) {
                case o: SimpleDataObject =>
                    if (o.typeInfo.qualifiedName != TypeInfo.of<T>().qualifiedName) {
                        return None<T>
                    }
                case _ =>
                    // 非对象数据配对象型 T：类型不符，不能返回默认对象
                    if (isObjectPayload<T>()) {
                        return None<T>
                    }
            }
            match (T.tryFromData(data)) {
                case x: ?T => x
                case x: T => Some(x)
                case _ => None<T>
            }
        } catch (_: Exception) {
            None<T>
        } finally {
            codec.release()
        }
    }
}

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

    /**
     * 载荷读取的唯一实现：类型闸门 + 严格转换。
     *
     * 1. 自描述对象必须与 `T` 同名（`typeInfo.qualifiedName`）；`T` 是对象而数据不是对象一律拒绝；
     * 2. `T` 是标量/字符串时不做跨类型兜底，由 `tryFromData` 精确匹配（`DataInt` 读不成 `String`）；
     * 3. 对象目标用严格转换（不夹带任何 `IGNORE_*` 位），字段缺失/改名/类型漂移 SHALL 失败，
     *    不得折成「字段全默认」的半成品对象；
     * 4. 读取过程不抛异常：损坏字节、空载荷与类型不符统一 `None`。
     */
    private static func readPayload<T>(data: Data): ?T where T <: DataFields<T> {
        let objectTarget = !T.isSimple()
        match (data) {
            case o: SimpleDataObject =>
                if (o.typeInfo.qualifiedName != TypeInfo.of<T>().qualifiedName) {
                    return None<T>
                }
            case d: DataAny => return readPayload<T>(d.data)
            case _ =>
                if (objectTarget) {
                    return None<T>
                }
                if (!scalarTypeMatches<T>(data)) {
                    return None<T>
                }
        }
        // 对象严格转换：`0` 表示不忽略任何字段问题，字段漂移不产出「字段全默认」的实例。
        // 标量沿用默认标志：数值宽度之间的转换由 `tryFromData` 决定，跨类兜底已在闸门处挡掉。
        let flag: DataConversionFlag = if (objectTarget) {
            0
        } else {
            DEFAULT_DATA_FLAG
        }
        try {
            match (T.tryFromData(data, flag)) {
                case x: ?T => x
                case x: T => Some(x)
                case _ => None<T>
            }
        } catch (_: Exception) {
            None<T>
        }
    }

    /**
     * 标量目标的 `Data` 子类型匹配：只有对应子类型才算命中，不做跨类兜底。
     *
     * `DataReal` 读成 `String`、`DataString` 读成整数、`DataBool` 读成数值都返回 `false`；
     * 数值宽度之间（`DataReal` → `Int64`/`Float64` …）放行。
     */
    private static func scalarTypeMatches<T>(data: Data): Bool {
        let stringTarget = TypeInfo.of<T>().qualifiedName == TypeInfo.of<String>().qualifiedName
        let boolTarget = TypeInfo.of<T>().qualifiedName == TypeInfo.of<Bool>().qualifiedName
        match (data) {
            case _: DataNone => true
            case _: DataString => stringTarget
            case _: DataBool => boolTarget
            case _ => !stringTarget && !boolTarget
        }
    }

    /** 把载荷转换为对象或标量；类型不匹配返回 `None`，不抛异常。 */
    public static func asPayload<T>(message: Message): ?T where T <: DataFields<T> {
        readPayload<T>(message.data)
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

    /**
     * 内部子载荷解码。
     *
     * 与 `asPayload` 共用 `readPayload` 的类型闸门与转换标志，二者对同一段字节结论一致：
     * 1. 解出来是对象时，类全名必须等于 `T`；
     * 2. `T` 是对象类型（`isSimple() == false`）而解出来不是对象时，直接拒绝；
     * 3. 对象按严格转换，字段漂移不产出「字段全默认」的实例。
     */
    public static func decodePayload<T>(blob: MQBlob): ?T where T <: DataFields<T> {
        decodePayload<T>(blob.copyBytes())
    }

    /** 从字节解出自描述值；损坏或类型不符返回 `None`。 */
    public static func decodePayload<T>(bytes: Array<Byte>): ?T where T <: DataFields<T> {
        if (bytes.size == 0) {
            return None<T>
        }
        let codec = DefaultCodec()
        try {
            let data = codec.decodeData(ByteBuffer(bytes))
            // 与 `asPayload` 共用同一套闸门与转换标志，保证两个 API 对同一段字节同结论。
            readPayload<T>(data)
        } catch (_: Exception) {
            None<T>
        } finally {
            codec.release()
        }
    }
}

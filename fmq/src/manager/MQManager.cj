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
package fountain::fmq.manager

import std.collection.ArrayList
import std.convert.*
import fountain::f_data.*
import fountain::f_data.DataAny
import fountain::f_mq.base.*
import fountain::f_mq.base.model.*
import fountain::f_mq.base.payload.*
import fountain::f_net.client.Client
import fountain::f_protocol.default.{Message, Command}

/**
 * `fmq manager`：七个子命令，每个命令「建连 → 单次请求 → 渲染 → 关闭」。
 */
public class MQManager {
    private static let CONNECTION_FAILED = "无法连接消息队列服务"
    private static let TIMEOUT = Duration.second * 5

    private let args: MQManagerArgs
    /** 输出出口：CLI 默认打印，用例注入收集器后断言完整文本。 */
    private let sink: (String) -> Unit

    public init(args: MQManagerArgs) {
        this.args = args
        this.sink = {line => println(line)}
    }

    /** 注入输出出口（用例断言输出文案，不依赖 stdout 重定向）。 */
    public init(args: MQManagerArgs, sink: (String) -> Unit) {
        this.args = args
        this.sink = sink
    }

    private func emit(line: String): Unit {
        sink(line)
    }

    public func run(): Int64 {
        if (args.server.isEmpty()) {
            emit(MQManagerOutput.error(CONNECTION_FAILED))
            return 1
        }
        match (args.command) {
            case "registerTopic" =>
                let queueNum = match (Int64.tryParse(args.operands[1])) {
                    case Some(value) => value
                    case None =>
                        emit(MQManagerOutput.error("队列数必须是整数"))
                        return 2
                }
                var delayingMs = 0i64
                if (args.operands.size >= 3) {
                    let text = args.operands[2]
                    if (!text.startsWith("delaying=")) {
                        emit(MQManagerOutput.error("第三个参数必须是 delaying=<时长>"))
                        return 2
                    }
                    match (Duration.tryParse(text["delaying=".size..])) {
                        case None =>
                            emit(MQManagerOutput.error("delaying 不是合法时长"))
                            return 2
                        case Some(value) =>
                            if (value < Duration.Zero) {
                                emit(MQManagerOutput.error("delaying 不能为负"))
                                return 2
                            }
                            delayingMs = value.toMilliseconds()
                    }
                }
                registerTopic(args.operands[0], queueNum, delayingMs: delayingMs)
            case "deleteTopic" => deleteTopic(args.operands[0])
            case "registerSubscriber" => registerSubscriber(args.operands[0], args.operands[1])
            case "deleteSubscribeGroup" => deleteSubscribeGroup(args.operands[0], args.operands[1])
            case "listTopics" => listTopics()
            case "listSubscribeGroups" => listSubscribeGroups(args.operands[0])
            case "stats" =>
                if (args.operands.size == 0) {
                    stats("")
                } else {
                    stats(args.operands[0])
                }
            case _ =>
                emit(MQManagerArgs.helpText())
                2
        }
    }

    public func registerTopic(topic: String, queueNum: Int64, delayingMs!: Int64 = 0): Int64 {
        if (!MQTopic.isValid(topic)) {
            return invalidTopic(topic)
        }
        withClient {client =>
            let response = exchange(client, MQProtocol.registerTopic(MQTopicMeta(topic, queueNum,
                delayingMs: delayingMs)))
            match (response) {
                case None => connectionFailed()
                case Some(message) =>
                    if (message.command == Command.ERROR) {
                        return printError(MQProtocol.asResult(message))
                    }
                    let assignment = MQProtocol.asPayload<MQTopicAssignment>(message).getOrThrow {
                        MQServiceFailure("响应不是 MQTopicAssignment")
                    }
                    emit(MQManagerOutput.registeredTopic(topic, queueNum, delayingMs, assignment.owners))
                    0
            }
        }
    }

    public func deleteTopic(topic: String): Int64 {
        if (!MQTopic.isValid(topic)) {
            return invalidTopic(topic)
        }
        withClient {client =>
            let response = exchange(client, MQProtocol.deregister(MQDeregisterPayload("topic", topic)))
            finish(response, {result => emit("${topic} 已删除")})
        }
    }

    public func registerSubscriber(topic: String, group: String): Int64 {
        if (!MQTopic.isValid(topic)) {
            return invalidTopic(topic)
        }
        // 组名非法时不发请求：服务端同样会拒，但本地失败能让脚本立刻拿到非 0 退出码
        if (!MQGroup.isValid(group)) {
            return invalidGroup(group)
        }
        withClient {client =>
            let response = exchange(client, MQProtocol.registerGroup(MQSubscribeGroupMeta(topic, group)))
            finish(response, {result => emit("订阅组 ${group} 已注册")})
        }
    }

    public func deleteSubscribeGroup(topic: String, group: String): Int64 {
        if (!MQTopic.isValid(topic)) {
            return invalidTopic(topic)
        }
        if (!MQGroup.isValid(group)) {
            return invalidGroup(group)
        }
        withClient {client =>
            let response = exchange(client,
                MQProtocol.deregister(MQDeregisterPayload("group", topic, subscribeGroup: group)))
            finish(response, {result => emit("订阅组 ${group} 已删除")})
        }
    }

    public func listTopics(): Int64 {
        withClient {client =>
            match (requestSnapshot(client)) {
                case SnapshotOutcome.Unreachable => connectionFailed()
                case SnapshotOutcome.Server(error) => printError(error)
                case SnapshotOutcome.Protocol(reason) => protocolError(reason)
                case SnapshotOutcome.Ok(value) =>
                    emit(MQManagerOutput.topicList(value))
                    0
            }
        }
    }

    public func listSubscribeGroups(topic: String): Int64 {
        if (!MQTopic.isValid(topic)) {
            return invalidTopic(topic)
        }
        withClient {client =>
            match (requestSnapshot(client)) {
                case SnapshotOutcome.Unreachable => connectionFailed()
                case SnapshotOutcome.Server(error) => printError(error)
                case SnapshotOutcome.Protocol(reason) => protocolError(reason)
                case SnapshotOutcome.Ok(value) =>
                    let rows = ArrayList<Array<String>>()
                    for (meta in value.groups) {
                        if (meta.topic == topic) {
                            let name = if (meta.subscribeGroup.isEmpty()) {
                                "（默认组）"
                            } else {
                                meta.subscribeGroup
                            }
                            rows.add([name])
                        }
                    }
                    emit(MQManagerOutput.table(["subscribeGroup"], rows.toArray()))
                    0
            }
        }
    }

    public func stats(topic: String): Int64 {
        // 空串表示「全部主题」，非空必须是绝对路径
        if (!topic.isEmpty() && !MQTopic.isValid(topic)) {
            return invalidTopic(topic)
        }
        withClient {client =>
            let response = exchange(client, MQProtocol.stats(topic))
            match (response) {
                case None => connectionFailed()
                case Some(message) =>
                    if (message.command == Command.ERROR) {
                        return printError(MQProtocol.asResult(message))
                    }
                    let text = match (MQProtocol.asPayload<String>(message)) {
                        case Some(value) => value
                        case None => throw MQServiceFailure("响应不是统计文本")
                    }
                    emit(MQManagerOutput.stats(text))
                    0
            }
        }
    }

    // ===== 内部 =====

    private func withClient(body: (Client<DataAny>) -> Int64): Int64 {
        var client: ?Client<DataAny> = None
        try {
            client = Some(Client<DataAny>.builder(
                address: args.server,
                checkDuration: Duration.second * 30,
                checker: {=> Message.ping()}
            ).pingTimeout(Duration.second * 2).build())
        } catch (_: Exception) {
            return connectionFailed()
        }
        try {
            body(client.getOrThrow())
        } catch (e: MQServiceFailure) {
            // 对端已回包但内容不符：协议错误，不能报成连接失败
            return report(Failure.Protocol(e.message))
        } catch (_: Exception) {
            return report(Failure.Unreachable)
        } finally {
            try {
                client.getOrThrow().close()
            } catch (_: Exception) {}
        }
    }

    private func exchange(client: Client<DataAny>, request: Message): ?Message {
        client.transfer(request, TIMEOUT)
    }

    private func finish(response: ?Message, onSuccess: (MQResult) -> Unit): Int64 {
        match (response) {
            case None => connectionFailed()
            case Some(message) =>
                let result = MQProtocol.asResult(message)
                if (result.code != 0) {
                    return printError(result)
                }
                onSuccess(result)
                0
        }
    }

    /**
     * 请求元数据快照。
     *
     * 必须区分「连不上」「服务端返回错误」「返回了非快照」三种情况：
     * 旧实现把后两者都折成 `None`，命令行会把服务端故障报成「无法连接」（A65）。
     */
    private func requestSnapshot(client: Client<DataAny>): SnapshotOutcome {
        let response = exchange(client, MQProtocol.metaSync(MQMetaSyncRequest(-1)))
        match (response) {
            case None => SnapshotOutcome.Unreachable
            case Some(message) =>
                if (message.command == Command.ERROR) {
                    return SnapshotOutcome.Server(MQProtocol.asResult(message))
                }
                match (MQProtocol.asPayload<MQMetaSnapshot>(message)) {
                    case Some(snapshot) => SnapshotOutcome.Ok(snapshot)
                    case None => SnapshotOutcome.Protocol("响应不是 MQMetaSnapshot")
                }
        }
    }

    /** 协议错误（对端回包但内容不符）：不能报成连接失败。 */
    private func protocolError(reason: String): Int64 {
        report(Failure.Protocol(reason))
    }

    private func printError(result: MQResult): Int64 {
        report(Failure.Server(result))
    }

    private func localError(reason: String): Int64 {
        report(Failure.Local(reason))
    }

    /** 主题非法：请求不发，文案里带错误码，脚本可直接匹配（R4-G1）。 */
    private func invalidTopic(topic: String): Int64 {
        localError("INVALID_TOPIC '${topic}', expect an absolute path such as /order")
    }

    /** 组名非法：同上（R4-G1）。 */
    private func invalidGroup(group: String): Int64 {
        localError("INVALID_GROUP '${group}'")
    }

    private func connectionFailed(): Int64 {
        report(Failure.Unreachable)
    }

    /** 四类失败统一出口：文案互斥，退出码统一为 1（本地解析错误另用 2）。 */
    private func report(failure: Failure): Int64 {
        let text = match (failure) {
            case Failure.Unreachable => CONNECTION_FAILED
            case Failure.Server(result) =>
                if (result.message.isEmpty()) {
                    MQErrorCode.messageOf(result.code)
                } else {
                    result.message
                }
            case Failure.Protocol(reason) => reason
            case Failure.Local(reason) => reason
        }
        emit(MQManagerOutput.error(text))
        1
    }
}

/**
 * 管理端失败分类：四类文案互斥，回归用例据此断言「不是所有失败都叫无法连接」。
 */
private enum Failure {
    | Unreachable
    | Server(MQResult)
    /** 对端回包但载荷类型/格式不符 */
    | Protocol(String)
    /** 本地参数/配置非法，请求未发出 */
    | Local(String)
}

/** 本地响应格式错误（与连接失败区分）。 */
class MQServiceFailure <: Exception {
    init(message: String) {
        super(message)
    }
}

/** 快照请求的四种结局。 */
private enum SnapshotOutcome {
    | Ok(MQMetaSnapshot)
    | Server(MQResult)
    | Protocol(String)
    | Unreachable
}

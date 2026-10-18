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
 * `fmq manager`：六个子命令，每个命令「建连 → 单次请求 → 渲染 → 关闭」。
 */
public class MQManager {
    private static let CONNECTION_FAILED = "无法连接消息队列服务"
    private static let TIMEOUT = Duration.second * 5

    private let args: MQManagerArgs

    public init(args: MQManagerArgs) {
        this.args = args
    }

    public func run(): Int64 {
        if (args.server.isEmpty()) {
            println(MQManagerOutput.error(CONNECTION_FAILED))
            return 1
        }
        match (args.command) {
            case "registerTopic" =>
                let queueNum = match (Int64.tryParse(args.operands[1])) {
                    case Some(value) => value
                    case None =>
                        println(MQManagerOutput.error("队列数必须是整数"))
                        return 2
                }
                var delayingMs = 0i64
                if (args.operands.size >= 3) {
                    let text = args.operands[2]
                    if (!text.startsWith("delaying=")) {
                        println(MQManagerOutput.error("第三个参数必须是 delaying=<时长>"))
                        return 2
                    }
                    match (Duration.tryParse(text["delaying=".size..])) {
                        case None =>
                            println(MQManagerOutput.error("delaying 不是合法时长"))
                            return 2
                        case Some(value) =>
                            if (value < Duration.Zero) {
                                println(MQManagerOutput.error("delaying 不能为负"))
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
                println(MQManagerArgs.helpText())
                2
        }
    }

    public func registerTopic(topic: String, queueNum: Int64, delayingMs!: Int64 = 0): Int64 {
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
                    let parts = ArrayList<String>()
                    for (i in 0..assignment.owners.size) {
                        parts.add("${i}→${assignment.owners[i]}")
                    }
                    let delay = (Duration.millisecond * delayingMs).toString()
                    println("${topic} 已注册，队列 0..${queueNum - 1}，延迟：${delay}，分配：${join(parts)}")
                    0
            }
        }
    }

    public func deleteTopic(topic: String): Int64 {
        withClient {client =>
            let response = exchange(client, MQProtocol.deregister(MQDeregisterPayload("topic", topic)))
            finish(response, {result => println("${topic} 已删除")})
        }
    }

    public func registerSubscriber(topic: String, group: String): Int64 {
        withClient {client =>
            let response = exchange(client, MQProtocol.registerGroup(MQSubscribeGroupMeta(topic, group)))
            finish(response, {result => println("订阅组 ${group} 已注册")})
        }
    }

    public func deleteSubscribeGroup(topic: String, group: String): Int64 {
        withClient {client =>
            let response = exchange(client,
                MQProtocol.deregister(MQDeregisterPayload("group", topic, subscribeGroup: group)))
            finish(response, {result => println("订阅组 ${group} 已删除")})
        }
    }

    public func listTopics(): Int64 {
        withClient {client =>
            let snapshot = requestSnapshot(client)
            match (snapshot) {
                case None => connectionFailed()
                case Some(value) =>
                    let rows = ArrayList<Array<String>>()
                    for (assignment in value.topics) {
                        let owners = ArrayList<String>()
                        for (index in 0..assignment.owners.size) {
                            owners.add("${index}→${assignment.owners[index]}")
                        }
                        rows.add([assignment.topic, "${assignment.queueNum}",
                            (Duration.millisecond * assignment.delayingMs).toString(), join(owners)])
                    }
                    println(MQManagerOutput.table(["topic", "queueNum", "delaying", "分配"], rows.toArray()))
                    0
            }
        }
    }

    public func listSubscribeGroups(topic: String): Int64 {
        withClient {client =>
            let snapshot = requestSnapshot(client)
            match (snapshot) {
                case None => connectionFailed()
                case Some(value) =>
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
                    println(MQManagerOutput.table(["subscribeGroup"], rows.toArray()))
                    0
            }
        }
    }

    public func stats(topic: String): Int64 {
        withClient {client =>
            let response = exchange(client, MQProtocol.stats(topic))
            match (response) {
                case None => connectionFailed()
                case Some(message) =>
                    if (message.command == Command.ERROR) {
                        return printError(MQProtocol.asResult(message))
                    }
                    let text = convert<String>(message.data).getOrThrow {
                        MQServiceFailure("响应不是统计文本")
                    }
                    let rows = ArrayList<Array<String>>()
                    for (line in text.split("\n")) {
                        if (!line.startsWith("R\t")) {
                            continue
                        }
                        let fields = line.split("\t")
                        if (fields.size < 12) {
                            continue
                        }
                        let group = if (fields[2].size == 0) {
                            "（无）"
                        } else {
                            fields[2]
                        }
                        let delay = (Duration.millisecond * Int64.parse(fields[4])).toString()
                        rows.add([fields[1], group, fields[3], delay, fields[6], fields[7], fields[8], fields[9],
                            fields[10], fields[11]])
                    }
                    println(MQManagerOutput.table(
                        ["topic", "group", "queueNum", "delaying", "backlog", "lagMs", "delivered", "acked",
                            "redelivered", "deadLettered"], rows.toArray()))
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
        } catch (_: MQServiceFailure) {
            println(MQManagerOutput.error("服务端响应格式不正确"))
            1
        } catch (_: Exception) {
            connectionFailed()
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

    private func requestSnapshot(client: Client<DataAny>): ?MQMetaSnapshot {
        let response = exchange(client, MQProtocol.metaSync(MQMetaSyncRequest(-1)))
        match (response) {
            case None => None<MQMetaSnapshot>
            case Some(message) => MQProtocol.asPayload<MQMetaSnapshot>(message)
        }
    }

    private func printError(result: MQResult): Int64 {
        let text = if (result.message.isEmpty()) {
            MQErrorCode.messageOf(result.code)
        } else {
            result.message
        }
        println(MQManagerOutput.error(text))
        1
    }

    private func connectionFailed(): Int64 {
        println(MQManagerOutput.error(CONNECTION_FAILED))
        1
    }

    private static func join(parts: ArrayList<String>): String {
        let out = StringBuilder()
        for (i in 0..parts.size) {
            if (i > 0) {
                out.append(',')
            }
            out.append(parts[i])
        }
        out.toString()
    }
}

/** 本地响应格式错误（与连接失败区分）。 */
class MQServiceFailure <: Exception {
    init(message: String) {
        super(message)
    }
}

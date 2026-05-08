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
package fountain::fmq.cli

import std.collection.ArrayList
import std.convert.Parsable

/**
 * 命令运行器。
 * 每个命令对应一个 static 方法，解析参数并输出结果。
 *
 * Phase 8 为骨架占位，真实操作将在后续阶段对接 MQ 节点。
 */
public class CommandRunner {
    private static let log = LoggerFactory.getLogger('fountain::fmq.CommandRunner')

    /**
     * 从参数数组中提取 --name <value> 格式的值。
     */
    private static func getArg(args: Array<String>, flag: String): ?String {
        for (i in 0..args.size) {
            if (args[i] == flag && i + 1 < args.size) {
                return Some(args[i + 1])
            }
        }
        None
    }

    // ───── 主题管理 ─────

    public static func createTopic(args: Array<String>): Unit {
        let name = getArg(args, "--name")
        let queues = getArg(args, "--queues")
        if (let Some(n) <- name) {
            let q = if (let Some(s) <- queues) { Int64.parse(s) } else { 1 }
            println("createTopic: ${n}, queues=${q} (placeholder)")
        } else {
            println("error: --name is required")
        }
    }

    public static func deleteTopic(args: Array<String>): Unit {
        let name = getArg(args, "--name")
        if (let Some(n) <- name) {
            println("deleteTopic: ${n} (placeholder)")
        } else {
            println("error: --name is required")
        }
    }

    // ───── 消费者组管理 ─────

    public static func createConsumerGroup(args: Array<String>): Unit {
        let name = getArg(args, "--name")
        let topic = getArg(args, "--topic")
        if (let Some(n) <- name) {
            if (let Some(t) <- topic) {
                println("createConsumerGroup: ${n} for topic ${t} (placeholder)")
            } else {
                println("error: --topic is required")
            }
        } else {
            println("error: --name is required")
        }
    }

    public static func deleteConsumerGroup(args: Array<String>): Unit {
        let name = getArg(args, "--name")
        let topic = getArg(args, "--topic")
        if (let Some(n) <- name && let Some(t) <- topic) {
            println("deleteConsumerGroup: ${n} for topic ${t} (placeholder)")
        } else {
            println("error: --name and --topic are required")
        }
    }

    // ───── 列表查询 ─────

    public static func listTopics(_: Array<String>): Unit {
        println("topics: (placeholder)")
    }

    public static func listConsumerGroups(_: Array<String>): Unit {
        println("consumer groups: (placeholder)")
    }

    public static func listGroups(args: Array<String>): Unit {
        let topic = getArg(args, "--topic")
        if (let Some(t) <- topic) {
            println("groups for topic ${t}: (placeholder)")
        } else {
            println("error: --topic is required")
        }
    }

    public static func listConsumers(args: Array<String>): Unit {
        let topic = getArg(args, "--topic")
        if (let Some(t) <- topic) {
            println("consumers for topic ${t}: (placeholder)")
        } else {
            println("error: --topic is required")
        }
    }

    // ───── 运维操作 ─────

    public static func resetOffset(args: Array<String>): Unit {
        let topic = getArg(args, "--topic")
        let group = getArg(args, "--group")
        let offset = getArg(args, "--offset")
        if (let Some(t) <- topic && let Some(g) <- group && let Some(o) <- offset) {
            println("resetOffset: ${t}/${g} => ${o} (placeholder)")
        } else {
            println("error: --topic, --group, --offset are required")
        }
    }

    public static func showTopic(args: Array<String>): Unit {
        let name = getArg(args, "--name")
        if (let Some(n) <- name) {
            println("topic ${n}: (placeholder)")
        } else {
            println("error: --name is required")
        }
    }

    public static func showBrokers(_: Array<String>): Unit {
        println("brokers: (placeholder)")
    }

    // ───── 死信管理 ─────

    public static func listDeadLetters(args: Array<String>): Unit {
        let topic = getArg(args, "--topic")
        let queue = getArg(args, "--queue")
        if (let Some(t) <- topic && let Some(q) <- queue) {
            let qi = Int64.parse(q)
            let client = getClient()
            let entries = client.listDeadLetters(t, qi)
            if (entries.size == 0) {
                println("no dead letters for ${t}[${q}]")
            } else {
                println("dead letters for ${t}[${q}]:")
                for ((msgId, data) in entries) {
                    println("  ${msgId} (${data.size} bytes)")
                }
            }
        } else {
            println("error: --topic and --queue are required")
        }
    }

    public static func redeliverDeadLetter(args: Array<String>): Unit {
        let topic = getArg(args, "--topic")
        let queue = getArg(args, "--queue")
        let msgId = getArg(args, "--messageId")
        if (let Some(t) <- topic && let Some(q) <- queue && let Some(m) <- msgId) {
            let qi = Int64.parse(q)
            let client = getClient()
            if (client.redeliverDeadLetter(t, qi, m)) {
                println("redelivered ${m} from ${t}[${q}]")
            } else {
                println("failed to redeliver ${m}")
            }
        } else {
            println("error: --topic, --queue, --messageId are required")
        }
    }

    public static func redeliverAllDeadLetters(args: Array<String>): Unit {
        let topic = getArg(args, "--topic")
        let queue = getArg(args, "--queue")
        if (let Some(t) <- topic && let Some(q) <- queue) {
            let qi = Int64.parse(q)
            let client = getClient()
            if (client.redeliverAllDeadLetters(t, qi)) {
                println("redelivered all from ${t}[${q}]")
            } else {
                println("failed to redeliver all from ${t}[${q}]")
            }
        } else {
            println("error: --topic and --queue are required")
        }
    }

    /**
     * 获取 MQ 客户端连接。
     */
    private static func getClient(): MqClient {
        let config = loadConfig()
        MqClient.getInstance(config)
    }
}

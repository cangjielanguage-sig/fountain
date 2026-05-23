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

import std.collection.*
import std.convert.*
import std.sync.Mutex

/**
 * 命令运行器。
 * 每个命令对应一个 static 方法，解析参数并输出结果。
 * 所有命令返回 Bool 表示成功/失败。
 */
public class CommandRunner {
    private static var cachedConfig: Option<MqConfig> = None
    private static let configLock = Mutex()

    /**
     * 从参数数组中提取 --name <value> 格式的值。
     */
    internal static func getArg(args: Array<String>, flag: String): ?String {
        let prefix = flag + "="
        for (i in 0..args.size) {
            if (args[i] == flag && i + 1 < args.size) {
                return Some(args[i + 1])
            }
            if (args[i].startsWith(prefix)) {
                return Some(args[i][prefix.size..])
            }
        }
        None
    }

    /**
     * 校验 topic --name 参数。CLI-5: 统一校验，避免空/无效名发送到服务端。
     */
    internal static func validTopicName(name: String, cmd: String): Bool {
        if (name.isEmpty()) {
            println("error: --name must not be empty")
            return false
        }
        if (!name.startsWith("/")) {
            println("error: --name must start with '/'")
            return false
        }
        true
    }

    // ───── 主题管理 ─────

    public static func createTopic(args: Array<String>): Bool {
        let name = getArg(args, "--name")
        let queues = getArg(args, "--queues")
        if (let Some(n) <- name) {
            if (!validTopicName(n, "createTopic")) { return false }
            var q: Int64 = 1
            var usingDefault = false
            if (let Some(s) <- queues) {
                if (let Some(v) <- Int64.tryParse(s)) { q = v }
                else { println("error: --queues must be a number, got '${s}'"); return false }
            } else { usingDefault = true }
            if (usingDefault) { println("using default queue count: 1") }
            let client = if (let Some(c) <- getClient()) { c } else { return false }
            if (client.createTopic(n, queueCount: q)) {
                println("created topic '${n}' with ${q} queues")
                true
            } else {
                println("failed to create topic '${n}'")
                false
            }
        } else {
            println("error: --name is required")
            false
        }
    }

    public static func deleteTopic(args: Array<String>): Bool {
        let name = getArg(args, "--name")
        if (let Some(n) <- name) {
            if (!validTopicName(n, "deleteTopic")) { return false }
            let client = if (let Some(c) <- getClient()) { c } else { return false }
            if (client.deleteTopic(n)) {
                println("deleted topic '${n}'")
                true
            } else {
                println("failed to delete topic '${n}'")
                false
            }
        } else {
            println("error: --name is required")
            false
        }
    }

    // ───── 消费者组管理 ─────

    public static func createConsumerGroup(args: Array<String>): Bool {
        let name = getArg(args, "--name")
        let topic = getArg(args, "--topic")
        if (let Some(n) <- name && let Some(t) <- topic) {
            let client = if (let Some(c) <- getClient()) { c } else { return false }
            if (client.addConsumerGroup(t, n)) {
                println("created consumer group '${n}' for topic ${t}")
                true
            } else {
                println("failed to create consumer group '${n}'")
                false
            }
        } else {
            println("error: --name and --topic are required")
            false
        }
    }

    public static func deleteConsumerGroup(args: Array<String>): Bool {
        let name = getArg(args, "--name")
        let topic = getArg(args, "--topic")
        if (let Some(n) <- name && let Some(t) <- topic) {
            let client = if (let Some(c) <- getClient()) { c } else { return false }
            if (client.removeConsumerGroup(t, n)) {
                println("deleted consumer group '${n}' from topic ${t}")
                true
            } else {
                println("failed to delete consumer group '${n}'")
                false
            }
        } else {
            println("error: --name and --topic are required")
            false
        }
    }

    // ───── 列表查询 ─────

    public static func listTopics(_: Array<String>): Bool {
        let client = if (let Some(c) <- getClient()) { c } else { return false }
        let topics = client.listTopics()
        if (topics.size == 0) {
            println("no topics")
        } else {
            println("topics:")
            for (t in topics) {
                println("  ${t}")
            }
        }
        true
    }

    public static func listConsumerGroups(_: Array<String>): Bool {
        let client = if (let Some(c) <- getClient()) { c } else { return false }
        let all = client.listAllConsumerGroups()
        if (all.size == 0) {
            println("no consumer groups")
            return true
        }
        // 按 topic 分组输出（使用 HashMap 确保不依赖迭代顺序）
        var groupsByTopic = HashMap<String, ArrayList<String>>()
        for ((topic, group) in all) {
            if (let Some(groups) <- groupsByTopic.get(topic)) {
                groups.add(group)
            } else {
                let groups = ArrayList<String>()
                groups.add(group)
                groupsByTopic[topic] = groups
            }
        }
        for ((topic, groups) in groupsByTopic) {
            println("  ${topic}:")
            for (g in groups) {
                println("    ${g}")
            }
        }
        true
    }

    public static func listGroups(args: Array<String>): Bool {
        let topic = getArg(args, "--topic")
        if (let Some(t) <- topic) {
            let client = if (let Some(c) <- getClient()) { c } else { return false }
            let groups = client.listGroups(t)
            if (groups.size == 0) {
                println("no groups for topic ${t}")
            } else {
                println("groups for topic ${t}:")
                for (g in groups) {
                    println("  ${g}")
                }
            }
            true
        } else {
            println("error: --topic is required")
            false
        }
    }

    public static func listConsumers(args: Array<String>): Bool {
        let topic = getArg(args, "--topic")
        if (let Some(t) <- topic) {
            let client = if (let Some(c) <- getClient()) { c } else { return false }
            let consumers = client.listConsumers(t)
            if (consumers.size == 0) {
                println("no online consumers for topic '${t}'")
            } else {
                println("online consumers (${consumers.size}) for topic '${t}':")
                for ((cid, gid, mode) in consumers) {
                    println("  ${cid}  group=${gid}  match=${mode}")
                }
            }
            true
        } else {
            println("error: --topic is required")
            false
        }
    }

    // ───── 运维操作 ─────

    public static func resetOffset(args: Array<String>): Bool {
        let topic = getArg(args, "--topic")
        let group = getArg(args, "--group")
        let offset = getArg(args, "--offset")
        let queue = getArg(args, "--queue")
        if (let Some(t) <- topic && let Some(g) <- group && let Some(o) <- offset) {
            let client = if (let Some(c) <- getClient()) { c } else { return false }
            if (let Some(v) <- Int64.tryParse(o)) {
                var qi: Int64 = 0
                if (let Some(qs) <- queue) {
                    if (let Some(qv) <- Int64.tryParse(qs)) { qi = qv }
                    else { println("error: --queue must be a number, got '${qs}'"); return false }
                }
                if (client.resetOffset(t, g, v, queueIndex: qi)) {
                    println("reset offset ${t}/${g} => ${v} (queue=${qi})")
                    true
                } else {
                    println("failed to reset offset")
                    false
                }
            } else {
                println("error: --offset must be a number, got '${o}'")
                false
            }
        } else {
            println("error: --topic, --group, --offset are required")
            false
        }
    }

    public static func showTopic(args: Array<String>): Bool {
        let name = getArg(args, "--name")
        if (let Some(n) <- name) {
            if (!validTopicName(n, "showTopic")) { return false }
            let client = if (let Some(c) <- getClient()) { c } else { return false }
            if (let Some(info) <- client.showTopic(n)) {
                println("topic '${n}':")
                println("  ${info}")
                true
            } else {
                println("topic '${n}' not found")
                false
            }
        } else {
            println("error: --name is required")
            false
        }
    }

    /**
     * 显示当前 MQ 集群节点信息。
     */
    public static func showBrokers(_: Array<String>): Bool {
        let config = getOrLoadConfig()
        println("mq_hosts: ${config.mqHosts}")
        println("sync_hosts: ${config.syncHosts}")
        true
    }

    // ───── 死信管理 ─────

    public static func listDeadLetters(args: Array<String>): Bool {
        let topic = getArg(args, "--topic")
        let queue = getArg(args, "--queue")
        if (let Some(t) <- topic && let Some(q) <- queue) {
            let qi = if (let Some(v) <- Int64.tryParse(q)) { v }
                else { println("error: --queue must be a number, got '${q}'"); return false }
            let client = if (let Some(c) <- getClient()) { c } else { return false }
            let entries = client.listDeadLetters(t, qi)
            if (entries.size == 0) {
                println("no dead letters for ${t}[${q}]")
            } else {
                println("dead letters for ${t}[${q}]:")
                for ((msgId, data) in entries) {
                    println("  ${msgId} (${data.size} bytes)")
                }
            }
            true
        } else {
            println("error: --topic and --queue are required")
            false
        }
    }

    public static func redeliverDeadLetter(args: Array<String>): Bool {
        let topic = getArg(args, "--topic")
        let queue = getArg(args, "--queue")
        let msgId = getArg(args, "--messageId")
        if (let Some(t) <- topic && let Some(q) <- queue && let Some(m) <- msgId) {
            let qi = if (let Some(v) <- Int64.tryParse(q)) { v }
                else { println("error: --queue must be a number, got '${q}'"); return false }
            let client = if (let Some(c) <- getClient()) { c } else { return false }
            if (client.redeliverDeadLetter(t, qi, m)) {
                println("redelivered ${m} from ${t}[${q}]")
                true
            } else {
                println("failed to redeliver ${m}")
                false
            }
        } else {
            println("error: --topic, --queue, --messageId are required")
            false
        }
    }

    public static func redeliverAllDeadLetters(args: Array<String>): Bool {
        let topic = getArg(args, "--topic")
        let queue = getArg(args, "--queue")
        if (let Some(t) <- topic && let Some(q) <- queue) {
            let qi = if (let Some(v) <- Int64.tryParse(q)) { v }
                else { println("error: --queue must be a number, got '${q}'"); return false }
            let client = if (let Some(c) <- getClient()) { c } else { return false }
            if (client.redeliverAllDeadLetters(t, qi)) {
                println("redelivered all from ${t}[${q}]")
                true
            } else {
                println("failed to redeliver all from ${t}[${q}]")
                false
            }
        } else {
            println("error: --topic and --queue are required")
            false
        }
    }

    /**
     * 获取或加载配置（缓存，避免重复解析环境变量）。
     */
    internal static func getOrLoadConfig(): MqConfig {
        synchronized(configLock) {
            if (let Some(c) <- cachedConfig) { return c }
            let config = loadConfig()
            cachedConfig = Some(config)
            config
        }
    }

    /**
     * 获取 MQ 客户端连接。异常时打印错误并返回 None。
     */
    private static func getClient(): ?MqClient {
        let config = getOrLoadConfig()
        try {
            Some(MqClient.getInstance(config))
        } catch (e: Exception) {
            println("error: failed to connect: ${e.message}")
            None
        }
    }
}

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
package fountain::fmqsub

import std.collection.*
import std.convert.*
import std.env.*
import std.fs.*
import fountain::f_app.{Initializer, InitializerCollection}
import fountain::f_mq.*

/**
 * 消息消费端（**动态库**，由 `fboot run --dylibPattern='(fmqsub)'` 加载，没有 main 函数）。
 *
 * 演示代码放在 `Initializer.start()` 里：启动即订阅、消费、逐条 ack，收满 `FMQDEMO_COUNT`
 * 条后返回（进程继续由 fboot 持有）。`FMQDEMO_AUTO_ACK=true` 时改由服务端在投递时自动确认。
 *
 * 环境变量：
 *   mqClient_hosts       节点表（逗号分隔 host:port，必填）
 *   FMQDEMO_TOPIC        主题（默认 /fmqdemo）
 *   FMQDEMO_GROUP        订阅组（默认 demoGroup，需先用 `fmq manager registerSubscriber` 注册）
 *   FMQDEMO_COUNT        条数（默认 10）
 *   FMQDEMO_TAGS         tags，逗号分隔（默认 demo）
 *   FMQDEMO_AUTO_ACK     true 时使用 autoAck（默认 false）
 *   FMQDEMO_LOG          事件文件（可选，每行 append 后立即 flush，供脚本编排/断言）
 */
public struct ConsumerInitializer <: Initializer {
    static init() {
        InitializerCollection.register(ConsumerInitializer())
    }

    private init() {}

    public prop name: String {
        get() {
            "fountain::fmqsub"
        }
    }

    public func initialize(): Unit {}

    public func start(): Unit {
        try {
            consumeAll()
        } catch (e: Exception) {
            demoSay("FMQSUB_FAILED ${e}")
        }
    }

    private func consumeAll(): Unit {
        let hosts = demoHosts()
        if (hosts.size == 0) {
            demoSay("FMQSUB_FAILED mqClient_hosts 未设置（形如 127.0.0.1:23700）")
            return
        }
        let topic = demoEnv("FMQDEMO_TOPIC", "/fmqdemo")
        let group = demoEnv("FMQDEMO_GROUP", "demoGroup")
        let count = demoEnvInt("FMQDEMO_COUNT", 10)
        let autoAck = demoEnv("FMQDEMO_AUTO_ACK", "false") == "true"
        let tags = demoTags()
        demoSay("FMQSUB_BEGIN topic=${topic} group=${group} count=${count} tags=${tags} autoAck=${autoAck} hosts=${hosts}")
        let client = MQClient(hosts)
        try {
            let sid = client.subscribe(topic, subscribeGroup: group, tags: tags, autoAck: autoAck)
            demoSay("SUBSCRIBED ${sid}")
            var consumed: Int64 = 0
            while (consumed < count) {
                let message = client.consume(sid)
                let body = message.get<String>() ?? ""
                demoSay(
                    "CONSUMED ${consumed} ${body} q=${message.queueIndex}:${message.segmentedIndex}:${message.segmentedOffset}")
                if (!autoAck) {
                    client.ack(sid, message.queueIndex, message.segmentedIndex, message.segmentedOffset)
                }
                consumed++
            }
            client.unsubscribe(sid)
            demoSay("CONSUME_DONE ${count}")
        } finally {
            client.close()
        }
    }
}

/**
 * 输出一行进度：同时写 stdout（人看）与 `FMQDEMO_LOG`（脚本断言）。
 *
 * stdout 重定向到文件时是带缓冲的（进程退出才刷），所以编排与断言一律读事件文件；
 * 事件文件用「追加 + 立即 flush + 关闭」写入，保证脚本能实时看到。
 */
func demoSay(line: String): Unit {
    println(line)
    match (getVariable("FMQDEMO_LOG")) {
        case Some(path) =>
            try {
                let file = File(path, OpenMode.Append)
                file.write("${line}\n".toArray())
                file.flush()
                file.close()
            } catch (_: Exception) {}
        case None => ()
    }
}

/** 读取字符串环境变量（缺省用 fallback）。 */
func demoEnv(name: String, fallback: String): String {
    getVariable(name) ?? fallback
}

/** 读取整数环境变量（缺失或非法用 fallback）。 */
func demoEnvInt(name: String, fallback: Int64): Int64 {
    match (getVariable(name)) {
        case Some(v) => Int64.tryParse(v) ?? fallback
        case None => fallback
    }
}

/** 读取 tags：逗号分隔、去空白、忽略空项。 */
func demoTags(): Array<String> {
    let raw = demoEnv("FMQDEMO_TAGS", "demo")
    let result = ArrayList<String>()
    for (item in raw.split(',')) {
        let tag = item.trimAscii()
        if (!tag.isEmpty()) {
            result.add(tag)
        }
    }
    result.toArray()
}

/** 读取节点表：逗号分隔、去空白、忽略空项。 */
func demoHosts(): Array<String> {
    let raw = demoEnv("mqClient_hosts", "")
    let result = ArrayList<String>()
    for (item in raw.split(',')) {
        let host = item.trimAscii()
        if (!host.isEmpty()) {
            result.add(host)
        }
    }
    result.toArray()
}

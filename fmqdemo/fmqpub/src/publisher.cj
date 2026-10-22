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
package fountain::fmqpub

import std.collection.*
import std.convert.*
import std.env.*
import std.fs.*
import fountain::f_app.{Initializer, InitializerCollection}
import fountain::f_mq.*

/**
 * 消息发布端（**动态库**，由 `fboot run --dylibPattern='(fmqpub)'` 加载，没有 main 函数）。
 *
 * 演示代码放在 `Initializer.start()` 里：f_app 在应用启动后另起线程调用它（见 f_app/src/App.cj
 * 的 `spawn { current().start() }`），因此这里的发布过程不会挡住其它初始化项。
 * 发布完 `FMQDEMO_COUNT` 条后返回，进程继续由 fboot 持有。
 *
 * 环境变量：
 *   mqClient_hosts       节点表（逗号分隔 host:port，必填）
 *   FMQDEMO_TOPIC        主题（默认 /fmqdemo）
 *   FMQDEMO_COUNT        条数（默认 10）
 *   FMQDEMO_TAGS         tags，逗号分隔（默认 demo）
 *   FMQDEMO_INTERVAL_MS  发布间隔毫秒（默认 50）
 *   FMQDEMO_BODY_PREFIX  BODY 前缀（默认 demo-msg，BODY 形如 demo-msg-0）
 *   FMQDEMO_LOG          事件文件（可选，每行 append 后立即 flush，供脚本编排/断言）
 */
public struct PublisherInitializer <: Initializer {
    static init() {
        InitializerCollection.register(PublisherInitializer())
    }

    private init() {}

    public prop name: String {
        get() {
            "fountain::fmqpub"
        }
    }

    public func initialize(): Unit {}

    public func start(): Unit {
        try {
            publishAll()
        } catch (e: Exception) {
            demoSay("FMQPUB_FAILED ${e}")
        }
    }

    private func publishAll(): Unit {
        let hosts = demoHosts()
        if (hosts.size == 0) {
            demoSay("FMQPUB_FAILED mqClient_hosts 未设置（形如 127.0.0.1:23700）")
            return
        }
        let topic = demoEnv("FMQDEMO_TOPIC", "/fmqdemo")
        let count = demoEnvInt("FMQDEMO_COUNT", 10)
        let intervalMs = demoEnvInt("FMQDEMO_INTERVAL_MS", 50)
        let tags = demoTags()
        let prefix = demoEnv("FMQDEMO_BODY_PREFIX", "demo-msg")
        demoSay("FMQPUB_BEGIN topic=${topic} count=${count} tags=${tags} hosts=${hosts}")
        let client = MQClient(hosts)
        try {
            for (i in 0..count) {
                let body = "${prefix}-${i}"
                client.publish(topic, body, tags: tags)
                demoSay("PUBLISHED ${i} ${body}")
                if (intervalMs > 0 && i + 1 < count) {
                    sleep(Duration.millisecond * intervalMs)
                }
            }
            demoSay("PUBLISH_DONE ${count}")
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

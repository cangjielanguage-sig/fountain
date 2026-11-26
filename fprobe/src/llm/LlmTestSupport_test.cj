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
package fountain::fprobe.llm

import std.collection.{ArrayList, HashMap}
import std.env.getTempDirectory
import std.fs.Directory
import fountain::f_probe.AlarmMessageChannel
import fountain::fprobe.tui.HistorySource

/** 固定回复的假 LLM，记录每次提示词。 */
class FakeLlm <: LlmClient {
    var calls: Int64 = 0
    var fail: Bool = false
    var defaultResponse: String = ""
    let prompts = ArrayList<String>()
    let responses = ArrayList<String>()
    private var next = 0

    init(defaultResponse!: String = "") {
        this.defaultResponse = defaultResponse
    }

    public func chat(prompt: String): String {
        calls += 1
        prompts.add(prompt)
        if (fail) {
            throw Exception("llm down")
        }
        if (next < responses.size) {
            let value = responses[next]
            next += 1
            return value
        }
        defaultResponse
    }
}

/** 只按 `node|metric` 返回预设历史点的替身。 */
class LlmFakeHistory <: HistorySource {
    private let data = HashMap<String, Array<Float64>>()

    init() {}

    func set(node: String, metric: String, values: Array<Float64>): Unit {
        data["${node}|${metric}"] = values
    }

    public func values(node: String, metric: String): Array<Float64> {
        match (data.get("${node}|${metric}")) {
            case Some(values) => values
            case None => Array<Float64>()
        }
    }
}

/** 记住发送内容与收件人的假渠道。 */
class FakeReplyChannel <: AlarmMessageChannel {
    let inbox = ArrayList<String>()
    let sent = ArrayList<String>()
    let sentTo = ArrayList<Array<String>>()
    private let conf: String
    private var next = 0

    init(conf: String) {
        this.conf = conf
    }

    public func send(message: String, receiver: Array<String>): Unit {
        sent.add(message)
        sentTo.add(receiver)
    }

    public func receive(): String {
        if (next >= inbox.size) {
            return ""
        }
        let value = inbox[next]
        next += 1
        value
    }

    public func replyConf(): String {
        conf
    }
}

func llmTempDir(): String {
    Directory.createTemp(getTempDirectory()).toString()
}

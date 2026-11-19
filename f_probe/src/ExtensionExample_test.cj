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
package fountain::f_probe

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.JsonObject

/**
 * 文档示例的可编译校验（`doc/contract.md`、`doc/extension-guide.md`）。
 *
 * 不加载真实 `.so`：这里直接调用注册表，验证示例中的实现与注册路径成立。
 */
@Test
public class ExtensionExample_test {
    @TestCase
    public func documentedExtensionRegisters(): Unit {
        ProbeRegistry.clear()
        AlarmChannelRegistry.clear()

        ProbeRegistry.registerAgent("k8s", {=> K8sProbeAgent()})
        AlarmChannelRegistry.registerChannel("webhook", {=> WebhookAlarmChannel()})

        let agent = ProbeRegistry.agent("k8s").getOrThrow()()
        @Assert(agent.kind, "k8s")
        @Assert(agent.host, "")
        @Assert(agent.data.contains("nodes"))
        @Assert(agent.data.contains("pods"))

        let channel = AlarmChannelRegistry.channel("webhook").getOrThrow()()
        @Assert(channel.replyConf(), "probe_channel_webhook_replyAccount")
        @Assert(channel.receive(), "")

        ProbeRegistry.clear()
        AlarmChannelRegistry.clear()
    }
}

class K8sProbeAgent <: ProbeAgent {
    public prop kind: String {
        get() {
            "k8s"
        }
    }

    public prop data: JsonObject {
        get() {
            let data = JsonObject()
            data.add("nodes", 3)
            data.add("pods", 42)
            data
        }
    }
}

class WebhookAlarmChannel <: AlarmMessageChannel {
    public func send(_: String, _: Array<String>): Unit {}

    public func receive(): String {
        ""
    }

    public func replyConf(): String {
        "probe_channel_webhook_replyAccount"
    }
}

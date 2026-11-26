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

import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*

@Test
public class AlarmMessageChannel_test {
    /** 只实现三个基础方法时，sendRich 退化为纯文本 send，附件与 HTML 被忽略。 */
    @TestCase
    public func sendRichFallsBackToPlainSend(): Unit {
        let channel = PlainOnlyChannel()
        let attachments = ArrayList<String>()
        attachments.add("/tmp/web1-cpu.svg")
        channel.sendRich("plain body", "<b>html body</b>", attachments.toArray(), ["ops@example.com"])

        @Assert(channel.sendCount, 1)
        @Assert(channel.lastMessage, "plain body")
        @Assert(channel.lastReceivers.size, 1)
        @Assert(channel.lastReceivers[0], "ops@example.com")
    }

    /** 没有待处理消息时 receive 返回空字符串。 */
    @TestCase
    public func emptyReceiveReturnsEmptyString(): Unit {
        let channel = PlainOnlyChannel()
        @Assert(channel.receive(), "")
    }
}

class PlainOnlyChannel <: AlarmMessageChannel {
    var sendCount = 0
    var lastMessage = ""
    var lastReceivers: Array<String> = []

    public func send(message: String, receiver: Array<String>): Unit {
        sendCount++
        lastMessage = message
        lastReceivers = receiver
    }

    public func receive(): String {
        ""
    }

    public func replyConf(): String {
        "probe_channel_plain_replyAccount"
    }
}

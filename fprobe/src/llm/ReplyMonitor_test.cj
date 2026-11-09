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

import std.collection.ArrayList
import std.fs.Path
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.*
import fountain::fprobe.channel.ChannelMessage

private func rawMessage(id: String, from: String, subject: String, body: String): String {
    JsonValue.from(ChannelMessage(id, from, subject, body).toData()).toString()
}

private class AuthorizedRecorder {
    let messages = ArrayList<ChannelMessage>()

    func handle(message: ChannelMessage): Unit {
        messages.add(message)
    }
}

/** 16.4：逐渠道 receive、非法消息跳过、未授权固定回复、授权与去重。 */
@Test
public class ReplyMonitor_test {
    @TestCase
    public func unauthorizedSenderGetsFixedReplyAndNoAction(): Unit {
        let channel = FakeReplyChannel("probe_channel_email_replyAccount")
        channel.inbox.add(rawMessage("m1", "bad@example.com", "同意", "同意执行 mute"))
        let store = ReplyStateStore(Path(llmTempDir()).join("state.json").toString())
        let recorder = AuthorizedRecorder()
        let warnings = ArrayList<String>()
        let monitor = ReplyMonitor([("email", channel)], store,
            {message => recorder.handle(message)},
            accounts: {_ => ["ops@example.com"]},
            logWarning: {message => warnings.add(message)},
            logError: {_ => ()})

        @Assert(monitor.pollOnce(), 1)
        @Assert(channel.sent.size, 1)
        @Assert(channel.sent[0], "本账号没有权限指挥智能体")
        @Assert(channel.sentTo[0][0], "bad@example.com")
        @Assert(recorder.messages.isEmpty())
        @Assert(store.isHandled("m1"))
    }

    @TestCase
    public func invalidMessageIsSkippedWithWarning(): Unit {
        let channel = FakeReplyChannel("probe_channel_email_replyAccount")
        channel.inbox.add("not a json message")
        let store = ReplyStateStore(Path(llmTempDir()).join("state.json").toString())
        let recorder = AuthorizedRecorder()
        let warnings = ArrayList<String>()
        let monitor = ReplyMonitor([("email", channel)], store,
            {message => recorder.handle(message)},
            accounts: {_ => ["ops@example.com"]},
            logWarning: {message => warnings.add(message)},
            logError: {_ => ()})

        @Assert(monitor.pollOnce(), 0)
        @Assert(channel.sent.isEmpty())
        @Assert(recorder.messages.isEmpty())
        @Assert(warnings.size, 1)
        @Assert(warnings[0].contains("email"))
    }

    @TestCase
    public func authorizedMessageIsHandledOnce(): Unit {
        let channel = FakeReplyChannel("probe_channel_email_replyAccount")
        channel.inbox.add(rawMessage("m2", "ops@example.com", "同意", "同意"))
        let store = ReplyStateStore(Path(llmTempDir()).join("state.json").toString())
        let recorder = AuthorizedRecorder()
        let monitor = ReplyMonitor([("email", channel)], store,
            {message => recorder.handle(message)},
            accounts: {_ => ["ops@example.com"]},
            logWarning: {_ => ()},
            logError: {_ => ()})

        @Assert(monitor.pollOnce(), 1)
        @Assert(recorder.messages.size, 1)
        @Assert(recorder.messages[0].id, "m2")
        @Assert(store.isHandled("m2"))

        channel.inbox.add(rawMessage("m2", "ops@example.com", "同意", "同意"))
        @Assert(monitor.pollOnce(), 0)
        @Assert(recorder.messages.size, 1)
    }

    @TestCase
    public func emptyInboxDoesNothing(): Unit {
        let channel = FakeReplyChannel("probe_channel_email_replyAccount")
        let store = ReplyStateStore(Path(llmTempDir()).join("state.json").toString())
        let monitor = ReplyMonitor([("email", channel)], store, {_ => ()},
            accounts: {_ => ["ops@example.com"]},
            logWarning: {_ => ()}, logError: {_ => ()})

        @Assert(monitor.pollOnce(), 0)
        @Assert(channel.sent.isEmpty())
    }
}

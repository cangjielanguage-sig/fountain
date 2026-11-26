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
package fountain::fprobe.channel

import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_probe.{AlarmMessageChannel, ProbeErrorCode, ProbeException}

private class RecordingChannel <: AlarmMessageChannel {
    public let messages = ArrayList<String>()
    private let failing: Bool

    init(failing!: Bool = false) {
        this.failing = failing
    }

    public func send(message: String, receiver: Array<String>): Unit {
        let _ = receiver
        if (failing) {
            throw Exception("transport down")
        }
        messages.add(message)
    }

    public func receive(): String {
        ""
    }

    public func replyConf(): String {
        ""
    }
}

/** 11.1：多渠道分发、单渠道失败隔离、未知渠道启动失败。 */
@Test
public class ChannelDispatcher_test {
    @TestCase
    public func eachChannelReceivesMessage(): Unit {
        let ok = RecordingChannel()
        let other = RecordingChannel()
        let dispatcher = ChannelDispatcher([("ok", ok), ("other", other)], ["ok", "other"])

        dispatcher.dispatch("hello", receivers: ["ops@example.com"])

        @Assert(ok.messages.size, 1)
        @Assert(ok.messages[0], "hello")
        @Assert(other.messages.size, 1)
    }

    @TestCase
    public func failingChannelDoesNotBlockOthers(): Unit {
        let ok = RecordingChannel()
        let bad = RecordingChannel(failing: true)
        let errors = ArrayList<String>()
        let warnings = ArrayList<String>()
        let dispatcher = ChannelDispatcher([("ok", ok), ("bad", bad)], ["ok", "bad"],
            logWarning: {message => warnings.add(message)},
            logError: {message => errors.add(message)})

        dispatcher.dispatch("hello", receivers: ["ops@example.com"])

        @Assert(ok.messages.size, 1)
        @Assert(errors.size, 1)
        @Assert(errors[0].contains("bad"))
        @Assert(errors[0].contains("transport down"))
        @Assert(warnings.size, 1)
    }

    @TestCase
    public func unknownChannelFailsAtStartup(): Unit {
        var caught = false
        try {
            ChannelDispatcher([("email", RecordingChannel())], ["email", "webhook"])
        } catch (e: ProbeException) {
            caught = true
            @Assert(e.code, ProbeErrorCode.CONFIG)
            @Assert(e.message.contains("webhook"))
        }
        @Assert(caught)
    }

    @TestCase
    public func richDispatchPassesHtmlAndAttachments(): Unit {
        let rich = RecordingRichChannel()
        let dispatcher = ChannelDispatcher([("email", rich)], ["email"])

        dispatcher.dispatchRich("text", "<p>html</p>", ["/tmp/a.svg"], receivers: ["ops@example.com"])

        @Assert(rich.texts.size, 1)
        @Assert(rich.texts[0], "text")
        @Assert(rich.htmls[0], "<p>html</p>")
        @Assert(rich.attachments[0].size, 1)
        @Assert(rich.attachments[0][0], "/tmp/a.svg")
    }
}

private class RecordingRichChannel <: AlarmMessageChannel {
    public let texts = ArrayList<String>()
    public let htmls = ArrayList<String>()
    public let attachments = ArrayList<Array<String>>()

    public func send(message: String, receiver: Array<String>): Unit {
        let _ = receiver
        texts.add(message)
    }

    public func sendRich(message: String, html: String, attachmentPaths: Array<String>,
        receiver: Array<String>): Unit {
        let _ = receiver
        texts.add(message)
        htmls.add(html)
        attachments.add(attachmentPaths)
    }

    public func receive(): String {
        ""
    }

    public func replyConf(): String {
        ""
    }
}

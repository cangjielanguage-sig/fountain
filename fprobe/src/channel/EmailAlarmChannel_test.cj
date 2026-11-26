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
import fountain::f_data.*
import fountain::fprobe.alarm.{AlarmEvent, AlarmEventType}

private class FakeMailTransport <: MailTransport {
    public let sent = ArrayList<OutgoingMail>()
    public var incoming: Array<ReceivedMail> = []
    public let listedLimits = ArrayList<Int64>()

    public func send(mail: OutgoingMail): Unit {
        sent.add(mail)
    }

    public func list(limit: Int64): Array<ReceivedMail> {
        listedLimits.add(limit)
        incoming
    }
}

private func firingEvent(): AlarmEvent {
    AlarmEvent(AlarmEventType.FIRING, "web1", "cpu-high", "cpu", "critical",
        Some(90.0), 85.0, 1710000000000, "CPU 使用率过高")
}

private func recoveryEvent(): AlarmEvent {
    AlarmEvent(AlarmEventType.RECOVERY, "web1", "cpu-high", "cpu", "critical",
        Some(10.0), 85.0, 1710000060000, "CPU 使用率已恢复")
}

/** 11.2 / 11.3：告警 HTML 横幅、字段表格、纯文本兜底与恢复配色。 */
@Test
public class EmailAlarmContent_test {
    @TestCase
    public func alarmMailHasBannerTableAndPlainText(): Unit {
        let transport = FakeMailTransport()
        let channel = EmailAlarmChannel(transport, "probe@example.com")
        let event = firingEvent()

        channel.send(event.format(), ["ops@example.com"])

        @Assert(transport.sent.size, 1)
        let mail = transport.sent[0]
        @Assert(mail.receivers.size, 1)
        @Assert(mail.receivers[0], "ops@example.com")
        @Assert(mail.subject.contains("web1"))
        @Assert(mail.html.contains("background"))
        @Assert(mail.html.contains("web1"))
        @Assert(mail.html.contains("cpu-high"))
        @Assert(mail.html.contains("90"))
        @Assert(mail.html.contains("85"))
        @Assert(mail.html.contains("<table"))
        @Assert(mail.text.contains("web1"))
        @Assert(mail.text.contains("cpu-high"))
        @Assert(mail.text.contains("90"))
        @Assert(mail.text.contains("85"))
    }

    @TestCase
    public func recoveryMailUsesGreenBannerAndRecoveredTitle(): Unit {
        let transport = FakeMailTransport()
        let channel = EmailAlarmChannel(transport, "probe@example.com")
        let event = recoveryEvent()

        channel.send(event.format(), ["ops@example.com"])

        let mail = transport.sent[0]
        @Assert(mail.html.contains("#27ae60"))
        @Assert(mail.html.contains("已恢复"))
        @Assert(!mail.html.contains("#c0392b"))
        @Assert(mail.text.contains("已恢复"))
    }

    @TestCase
    public func defaultReceiversAreUsedWhenNoneGiven(): Unit {
        let transport = FakeMailTransport()
        let channel = EmailAlarmChannel(transport, "probe@example.com",
            defaultReceivers: ["oncall@example.com"])

        channel.send(firingEvent().format(), [])

        @Assert(transport.sent[0].receivers.size, 1)
        @Assert(transport.sent[0].receivers[0], "oncall@example.com")
    }
}

/** 11.4：富消息的 HTML 正文与附件媒体类型。 */
@Test
public class EmailAlarmRich_test {
    @TestCase
    public func sendRichCarriesHtmlAndTypedAttachments(): Unit {
        let transport = FakeMailTransport()
        let channel = EmailAlarmChannel(transport, "probe@example.com")

        channel.sendRich("report text", "<h1>report</h1>",
            ["/tmp/web1-cpu.svg", "/tmp/web1-cpu.bin"], ["ops@example.com"])

        @Assert(transport.sent.size, 1)
        let mail = transport.sent[0]
        @Assert(mail.text, "report text")
        @Assert(mail.html, "<h1>report</h1>")
        @Assert(mail.attachments.size, 2)
        @Assert(mail.attachments[0].filename, "web1-cpu.svg")
        @Assert(mail.attachments[0].mediaType, "image/svg+xml")
        @Assert(mail.attachments[1].filename, "web1-cpu.bin")
        @Assert(mail.attachments[1].mediaType, "application/octet-stream")
    }
}

/** 11.5：只读收件，返回未读邮件映射的 JSON；无消息返回空串。 */
@Test
public class EmailAlarmReceive_test {
    @TestCase
    public func receiveReturnsLatestUnreadAsJson(): Unit {
        let transport = FakeMailTransport()
        transport.incoming = [
            ReceivedMail("2", "fan@example.com", "cpu-high", true, "please check", "<p>please check</p>"),
            ReceivedMail("1", "old@example.com", "done", false, "old", "")
        ]
        let channel = EmailAlarmChannel(transport, "probe@example.com", receiveLimit: 5)

        let json = channel.receive()
        @Assert(!json.isEmpty())
        @Assert(transport.listedLimits[0], 5)

        let message = DataObject<ChannelMessage>.populate(JsonValue.fromStr(json).toData()).getOrThrow()
        @Assert(message.id, "2")
        @Assert(message.from, "fan@example.com")
        @Assert(message.subject, "cpu-high")
        @Assert(message.body, "please check")
    }

    @TestCase
    public func receiveFallsBackToHtmlAndReturnsEmptyWhenNoUnread(): Unit {
        let transport = FakeMailTransport()
        transport.incoming = [ReceivedMail("3", "a@b", "html only", true, "", "<b>hi</b>")]
        let channel = EmailAlarmChannel(transport, "probe@example.com")
        let parsed = DataObject<ChannelMessage>.populate(
            JsonValue.fromStr(channel.receive()).toData()).getOrThrow()
        @Assert(parsed.body, "<b>hi</b>")

        transport.incoming = [ReceivedMail("1", "a@b", "read", false, "x", "")]
        @Assert(channel.receive(), "")
    }
}

/** 11.6：replyConf 返回配置键而不是配置值。 */
@Test
public class EmailAlarmReplyConf_test {
    @TestCase
    public func replyConfReturnsConfigKey(): Unit {
        let channel = EmailAlarmChannel(FakeMailTransport(), "probe@example.com")
        @Assert(channel.replyConf(), "probe_channel_email_replyAccount")
    }
}

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
package fountain::f_llm.channel

import std.collection.*
import std.fs.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*

import fountain::f_data.JsonString

@Test
class ChannelFunctions_test {
    @TestCase
    func testSendRoutesThroughMediator(): Unit {
        ChannelMediator.reset()
        let channel = FakeChannel('email', 'work')
        ChannelMediator.register(channel)

        let params = ChannelSendParam()
        params.nextEvent = 'done'
        params.platform = 'email'
        params.account = 'work'
        params.to = 'a@b.c'
        params.subject = '周报'
        params.text = '本周完成 3 项'
        let result = ChannelSendFunction().call(params)

        @Expect((result.result as JsonString).getOrThrow().value.contains('"ok":true'), true)
        @Expect(channel.sent.size, 1)
        @Expect(channel.sent[0].subject, '周报')
        ChannelMediator.reset()
    }

    @TestCase
    func testSendCarriesAttachments(): Unit {
        ChannelMediator.reset()
        let channel = FakeChannel('email', 'work')
        ChannelMediator.register(channel)

        let attachment = ChannelAttachmentParam()
        attachment.filename = 'report.pdf'
        attachment.path = '/tmp/report.pdf'
        let attachments = ArrayList<ChannelAttachmentParam>()
        attachments.add(attachment)

        let params = ChannelSendParam()
        params.nextEvent = 'done'
        params.platform = 'email'
        params.account = 'work'
        params.to = 'a@b.c'
        params.subject = '带附件'
        params.text = '正文'
        params.attachments = attachments
        let _ = ChannelSendFunction().call(params)

        @Expect(channel.sent.size, 1)
        @Expect(channel.sent[0].attachments.size, 1)
        @Expect(channel.sent[0].attachments[0].filename, 'report.pdf')
        ChannelMediator.reset()
    }

    @TestCase
    func testSendUnknownPlatformReturnsError(): Unit {
        ChannelMediator.reset()
        let params = ChannelSendParam()
        params.nextEvent = 'done'
        params.platform = 'wecom'
        params.account = 'bot'
        params.to = 'a@b.c'
        params.subject = 'x'
        params.text = 'y'

        let result = ChannelSendFunction().call(params)
        @Expect((result.result as JsonString).getOrThrow().value.contains('"ok":false'), true)
        @Expect((result.result as JsonString).getOrThrow().value.contains('not supported'), true)
    }

    @TestCase
    func testInboxPassesDownloadDirAndReturnsJson(): Unit {
        ChannelMediator.reset()
        let channel = FakeChannel('email', 'work')
        let attachments = ArrayList<InboundAttachment>()
        attachments.add(InboundAttachment('a.txt', 3, path: '/tmp/a.txt', saved: true))
        channel.inbox.add(InboundMessage('1', 'x@y.z', '第一封', text: 'hello',
            attachments: attachments))
        ChannelMediator.register(channel)

        let params = ChannelInboxParam()
        params.nextEvent = 'done'
        params.platform = 'email'
        params.account = 'work'
        params.limit = 5
        params.downloadDir = '/tmp/dl'
        let result = ChannelInboxFunction().call(params)

        @Expect(channel.lastDownloadDir, '/tmp/dl')
        @Expect((result.result as JsonString).getOrThrow().value.contains('a.txt'), true)
        @Expect((result.result as JsonString).getOrThrow().value.contains('第一封'), true)
        ChannelMediator.reset()
    }

    /** 端到端冒烟：装配 → 工具发送（带附件）→ 工具收信（落盘） */
    @TestCase
    func testSmokeSendThenInboxWithAttachment(): Unit {
        ChannelMediator.reset()
        let dir = '/tmp/fllm-channel-smoke-${DateTime.now().toUnixTimeStamp().toMilliseconds()}'
        Directory.create(Path(dir), recursive: true)
        let outPath = '${dir}/out.txt'
        let file = File.create(Path(outPath))
        file.write(Array<Byte>(3, repeat: 65))
        file.close()

        let transport = FakeEmailTransport()
        ChannelMediator.register(EmailChannel('work', 'bot@example.com', transport))

        let sendParam = ChannelSendParam()
        sendParam.nextEvent = 'done'
        sendParam.platform = 'email'
        sendParam.account = 'work'
        sendParam.to = 'a@b.c'
        sendParam.subject = '冒烟'
        sendParam.text = '正文'
        let attachment = ChannelAttachmentParam()
        attachment.filename = 'out.txt'
        attachment.path = outPath
        let attachments = ArrayList<ChannelAttachmentParam>()
        attachments.add(attachment)
        sendParam.attachments = attachments
        let sent = ChannelSendFunction().call(sendParam)
        @Expect((sent.result as JsonString).getOrThrow().value.contains('"ok":true'), true)

        let received = ArrayList<ReceivedAttachment>()
        received.add(ReceivedAttachment('in.txt', 3, { => Array<Byte>(3, repeat: 66) }))
        transport.inbox.add(ReceivedMail('9', 'x@y.z', '回信', text: '收到',
            attachments: received))

        let inboxParam = ChannelInboxParam()
        inboxParam.nextEvent = 'done'
        inboxParam.platform = 'email'
        inboxParam.account = 'work'
        inboxParam.downloadDir = dir
        let got = ChannelInboxFunction().call(inboxParam)
        let text = (got.result as JsonString).getOrThrow().value
        @Expect(text.contains('in.txt'), true)
        @Expect(text.contains('"saved":true'), true)
        @Expect(exists(Path('${dir}/in.txt')), true)
        ChannelMediator.reset()
    }

    @TestCase
    func testInboxEmptyReturnsArray(): Unit {
        ChannelMediator.reset()
        ChannelMediator.register(FakeChannel('email', 'work'))

        let params = ChannelInboxParam()
        params.nextEvent = 'done'
        params.platform = 'email'
        params.account = 'work'
        let result = ChannelInboxFunction().call(params)

        @Expect((result.result as JsonString).getOrThrow().value, '[]')
        ChannelMediator.reset()
    }
}

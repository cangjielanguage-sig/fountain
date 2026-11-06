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

/** 假 transport：记录发出的消息，回放预设的收件箱；不碰网络 */
class FakeEmailTransport <: EmailTransport {
    public let sent: ArrayList<OutboundMessage> = ArrayList<OutboundMessage>()
    public let senders: ArrayList<String> = ArrayList<String>()
    public var inbox: ArrayList<ReceivedMail> = ArrayList<ReceivedMail>()
    public var closed: Bool = false

    public func send(message: OutboundMessage, from: String): SendReceipt {
        sent.add(message)
        senders.add(from)
        SendReceipt.success(messageId: 'm-${sent.size}')
    }

    public func receive(limit: Int64): ArrayList<ReceivedMail> {
        let result = ArrayList<ReceivedMail>()
        for(item in inbox){
            if(Int64(result.size) >= limit){
                break
            }
            result.add(item)
        }
        result
    }

    public func close(): Unit {
        closed = true
    }
}

@Test
class EmailChannel_test {
    private static func tempDir(name: String): String {
        let dir = '/tmp/fllm-channel-${name}-${DateTime.now().toUnixTimeStamp().toMilliseconds()}'
        Directory.create(Path(dir), recursive: true)
        dir
    }

    @TestCase
    func testSendMapsMessageAndAttachments(): Unit {
        let dir = tempDir('send')
        let filePath = '${dir}/report.pdf'
        let file = File.create(Path(filePath))
        file.write(Array<Byte>(4, repeat: 65))
        file.close()

        let transport = FakeEmailTransport()
        let channel = EmailChannel('work', 'bot@example.com', transport)
        let attachments = ArrayList<OutboundAttachment>()
        attachments.add(OutboundAttachment('report.pdf', filePath))

        let receipt = channel.send(OutboundMessage('a@b.c', '日报', text: '正文', attachments: attachments))

        @Expect(receipt.ok, true)
        @Expect(transport.sent.size, 1)
        @Expect(transport.senders[0], 'bot@example.com')
        @Expect(transport.sent[0].subject, '日报')
        @Expect(transport.sent[0].text, '正文')
        @Expect(transport.sent[0].attachments.size, 1)
        @Expect(transport.sent[0].attachments[0].filename, 'report.pdf')
    }

    @TestCase
    func testSendFailsWhenAttachmentMissing(): Unit {
        let transport = FakeEmailTransport()
        let channel = EmailChannel('work', 'bot@example.com', transport)
        let attachments = ArrayList<OutboundAttachment>()
        attachments.add(OutboundAttachment('ghost.pdf', '/tmp/definitely-missing-${DateTime.now().toUnixTimeStamp().toMilliseconds()}.pdf'))

        let receipt = channel.send(OutboundMessage('a@b.c', '日报', text: '正文', attachments: attachments))

        @Expect(receipt.ok, false)
        @Expect(receipt.error.contains('ghost.pdf'), true)
        @Expect(transport.sent.size, 0)
    }

    @TestCase
    func testReceiveMapsMetadataWithoutDownload(): Unit {
        let transport = FakeEmailTransport()
        let attachments = ArrayList<ReceivedAttachment>()
        attachments.add(ReceivedAttachment('a.txt', 3, { => Array<Byte>(3, repeat: 65) }))
        attachments.add(ReceivedAttachment('b.txt', 4, { => Array<Byte>(4, repeat: 66) }))
        transport.inbox.add(ReceivedMail('1', 'x@y.z', '第一封', text: 'hello',
            receivedAt: '2026-11-06T09:00:00+08:00', unread: true, attachments: attachments))
        let channel = EmailChannel('work', 'bot@example.com', transport)

        let messages = channel.receive(10, '')

        @Expect(messages.size, 1)
        @Expect(messages[0].id, '1')
        @Expect(messages[0].subject, '第一封')
        @Expect(messages[0].text, 'hello')
        @Expect(messages[0].unread, true)
        @Expect(messages[0].attachments.size, 2)
        @Expect(messages[0].attachments[0].filename, 'a.txt')
        @Expect(messages[0].attachments[0].size, 3)
        @Expect(messages[0].attachments[0].saved, false)
    }

    @TestCase
    func testReceiveSavesAttachments(): Unit {
        let dir = tempDir('save')
        let transport = FakeEmailTransport()
        let attachments = ArrayList<ReceivedAttachment>()
        attachments.add(ReceivedAttachment('a.txt', 3, { => Array<Byte>(3, repeat: 65) }))
        transport.inbox.add(ReceivedMail('1', 'x@y.z', '带附件', attachments: attachments))
        let channel = EmailChannel('work', 'bot@example.com', transport)

        let messages = channel.receive(10, dir)

        @Expect(messages[0].attachments[0].saved, true)
        @Expect(exists(Path(messages[0].attachments[0].path)), true)
        @Expect(messages[0].attachments[0].error, '')
    }

    @TestCase
    func testAttachmentNameConflictIsSuffixed(): Unit {
        let dir = tempDir('conflict')
        let (firstPath, firstError) = AttachmentSink.save(dir, 'a.txt', Array<Byte>(1, repeat: 65))
        let (secondPath, secondError) = AttachmentSink.save(dir, 'a.txt', Array<Byte>(2, repeat: 66))

        @Expect(firstError, '')
        @Expect(secondError, '')
        @Expect(firstPath == secondPath, false)
        @Expect(secondPath.contains('a-2.txt'), true)
        @Expect(exists(Path(firstPath)), true)
        @Expect(exists(Path(secondPath)), true)
    }

    @TestCase
    func testAttachmentFailsWhenDirectoryMissing(): Unit {
        let missing = '/tmp/fllm-channel-missing-${DateTime.now().toUnixTimeStamp().toMilliseconds()}'
        let (path, error) = AttachmentSink.save(missing, 'a.txt', Array<Byte>(1, repeat: 65))

        @Expect(path, '')
        @Expect(error.contains('directory'), true)
    }

    @TestCase
    func testEmailProviderIsRegisteredOnLoad(): Unit {
        @Expect(ChannelMediator.providerPlatforms().contains('email'), true)
    }
}

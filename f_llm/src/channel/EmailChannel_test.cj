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
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*

import fountain::f_config.Config
import fountain::f_llm.config.LLMConfig

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
        // 附件白名单：不配就只能发无附件的信
        Config.set<String>([(LLMConfig.LLM_CHANNEL_SEND_ROOTS, dir)])
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
        Config.remove(LLMConfig.LLM_CHANNEL_SEND_ROOTS)
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

    /** 并发落盘：同名附件必须落到两个不同路径，互不覆盖 */
    @TestCase
    func testConcurrentSaveKeepsBothFiles(): Unit {
        let dir = tempDir('concurrent')
        let first = spawn {
            => AttachmentSink.save(dir, 'same.txt', Array<Byte>(2, repeat: 65))
        }
        let second = spawn {
            => AttachmentSink.save(dir, 'same.txt', Array<Byte>(2, repeat: 66))
        }
        let (pathA, errorA) = first.get()
        let (pathB, errorB) = second.get()

        @Expect(errorA, '')
        @Expect(errorB, '')
        @Expect(pathA == pathB, false)
        @Expect(exists(Path(pathA)), true)
        @Expect(exists(Path(pathB)), true)
    }

    @TestCase
    func testAttachmentFailsWhenDirectoryMissing(): Unit {
        let missing = '/tmp/fllm-channel-missing-${DateTime.now().toUnixTimeStamp().toMilliseconds()}'
        let (path, error) = AttachmentSink.save(missing, 'a.txt', Array<Byte>(1, repeat: 65))

        @Expect(path, '')
        @Expect(error.contains('directory'), true)
    }

    // ---------- 附件安全 ----------

    @TestCase
    func testBareNameStripsPathSegments(): Unit {
        @Expect(AttachmentSink.bareName('../../etc/passwd'), 'passwd')
        @Expect(AttachmentSink.bareName('a\\b\\c.txt'), 'c.txt')
        @Expect(AttachmentSink.bareName('..'), 'attachment.bin')
        @Expect(AttachmentSink.bareName(''), 'attachment.bin')
    }

    @TestCase
    func testSaveKeepsTraversalInsideDirectory(): Unit {
        let dir = tempDir('traversal')
        let (path, error) = AttachmentSink.save(dir, '../../evil.txt', Array<Byte>(1, repeat: 65))

        @Expect(error, '')
        @Expect(path.startsWith(dir), true)
        @Expect(exists(Path(path)), true)
        @Expect(path.contains('evil'), true)
    }

    @TestCase
    func testSendAllowsAttachmentInsideRoots(): Unit {
        let root = tempDir('roots-ok')
        let filePath = '${root}/a.txt'
        let file = File.create(Path(filePath))
        file.write(Array<Byte>(1, repeat: 65))
        file.close()

        Config.set<String>([(LLMConfig.LLM_CHANNEL_SEND_ROOTS, root)])
        try{
            let transport = FakeEmailTransport()
            let channel = EmailChannel('work', 'bot@example.com', transport)
            let attachments = ArrayList<OutboundAttachment>()
            attachments.add(OutboundAttachment('a.txt', filePath))

            let receipt = channel.send(OutboundMessage('x@y.z', '主题', text: '正文', attachments: attachments))
            @Expect(receipt.ok, true)
            @Expect(transport.sent.size, 1)
        }finally{
            Config.remove(LLMConfig.LLM_CHANNEL_SEND_ROOTS)
        }
    }

    @TestCase
    func testSendRejectsAttachmentOutsideRoots(): Unit {
        let root = tempDir('roots-in')
        let outside = tempDir('roots-out')
        let filePath = '${outside}/secret.txt'
        let file = File.create(Path(filePath))
        file.write(Array<Byte>(1, repeat: 65))
        file.close()

        Config.set<String>([(LLMConfig.LLM_CHANNEL_SEND_ROOTS, root)])
        try{
            let transport = FakeEmailTransport()
            let channel = EmailChannel('work', 'bot@example.com', transport)
            let attachments = ArrayList<OutboundAttachment>()
            attachments.add(OutboundAttachment('secret.txt', filePath))

            let receipt = channel.send(OutboundMessage('x@y.z', '主题', text: '正文', attachments: attachments))
            @Expect(receipt.ok, false)
            @Expect(receipt.error.contains('allowed roots'), true)
            @Expect(transport.sent.size, 0)
        }finally{
            Config.remove(LLMConfig.LLM_CHANNEL_SEND_ROOTS)
        }
    }

    @TestCase
    func testSendRejectsWhenRootsUnconfigured(): Unit {
        Config.remove(LLMConfig.LLM_CHANNEL_SEND_ROOTS)
        Config.remove(LLMConfig.FILE_SANDBOX_PATH)
        let dir = tempDir('roots-none')
        let filePath = '${dir}/a.txt'
        let file = File.create(Path(filePath))
        file.write(Array<Byte>(1, repeat: 65))
        file.close()

        let transport = FakeEmailTransport()
        let channel = EmailChannel('work', 'bot@example.com', transport)
        let attachments = ArrayList<OutboundAttachment>()
        attachments.add(OutboundAttachment('a.txt', filePath))

        let receipt = channel.send(OutboundMessage('x@y.z', '主题', text: '正文', attachments: attachments))
        @Expect(receipt.ok, false)
        @Expect(receipt.error.contains('not configured'), true)
        @Expect(transport.sent.size, 0)
    }

    @TestCase
    func testSendRejectsDirectoryAsAttachment(): Unit {
        let root = tempDir('roots-dir')
        let nested = '${root}/folder'
        Directory.create(Path(nested), recursive: true)

        Config.set<String>([(LLMConfig.LLM_CHANNEL_SEND_ROOTS, root)])
        try{
            let transport = FakeEmailTransport()
            let channel = EmailChannel('work', 'bot@example.com', transport)
            let attachments = ArrayList<OutboundAttachment>()
            attachments.add(OutboundAttachment('folder', nested))

            let receipt = channel.send(OutboundMessage('x@y.z', '主题', text: '正文', attachments: attachments))
            @Expect(receipt.ok, false)
            @Expect(transport.sent.size, 0)
        }finally{
            Config.remove(LLMConfig.LLM_CHANNEL_SEND_ROOTS)
        }
    }

    @TestCase
    func testEmailProviderIsRegisteredOnLoad(): Unit {
        @Expect(ChannelMediator.providerPlatforms().contains('email'), true)
    }

    /** 单个附件读取失败不应中断整批收信 */
    @TestCase
    func testAttachmentReadFailureDoesNotBreakBatch(): Unit {
        let transport = FakeEmailTransport()
        let broken = ArrayList<ReceivedAttachment>()
        broken.add(ReceivedAttachment('bad.txt', 3, { => throw IllegalStateException('imap body lost') }))
        transport.inbox.add(ReceivedMail('1', 'x@y.z', '第一封', text: 'a', attachments: broken))
        transport.inbox.add(ReceivedMail('2', 'x@y.z', '第二封', text: 'b'))

        let channel = EmailChannel('work', 'bot@example.com', transport)
        // 给下载目录才会真正调用 read()，从而触发「单条读到一半失败」
        let messages = channel.receive(10, tempDir('read-fail'))

        @Expect(messages.size, 2)
        @Expect(messages[0].attachments.size, 1)
        @Expect(messages[0].attachments[0].error.contains('imap body lost'), true)
        @Expect(messages[1].subject, '第二封')
    }

    /** 目标路径其实是文件：落盘失败并给出原因 */
    @TestCase
    func testSaveFailsWhenTargetIsAFile(): Unit {
        let dir = tempDir('notdir')
        let blocker = '${dir}/blocker'
        File.create(Path(blocker)).close()

        let (path, error) = AttachmentSink.save(blocker, 'a.txt', Array<Byte>(1, repeat: 65))
        @Expect(path, '')
        @Expect(error.isEmpty(), false)
    }

    /** 远端给的绝对路径被压成单文件名，落在下载目录内 */
    @TestCase
    func testAbsoluteRemoteNameIsNeutralized(): Unit {
        let dir = tempDir('absname')
        let (path, error) = AttachmentSink.save(dir, '/etc/passwd', Array<Byte>(1, repeat: 65))
        @Expect(error, '')
        @Expect(path, '${dir}/passwd')
    }
}

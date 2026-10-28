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
package fountain::f_email.mime

import std.collection.ArrayList
import std.io.{InputStream, OutputStream}
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_email.model.*

@Test
public class MimeWriter_test {
    @TestCase
    public func roundTripsChineseSubjectHtmlAndAttachment(): Unit {
        let payload: Array<Byte> = [0x00, 0x01, 0x02, 0xff, 0xfe]
        let message = MailMessage.builder()
            .from("发件人 <a@x.com>")
            .to("b@y.com")
            .subject("构建失败告警")
            .text("纯文本正文")
            .html("<p>HTML 正文</p>")
            .attach("build.bin", MemoryBodySource(payload))
            .build()
        let out = BufferOutput()
        let writer = MimeWriter(out)
        writer.write(message)
        @Assert(writer.bytesWritten() > 0, true)

        let parsed = MimeParser.parse(BufferInput(out.bytes()))
        @Assert(parsed.subject() ?? "", "构建失败告警")
        @Assert(parsed.text() ?? "", "纯文本正文")
        @Assert(parsed.html() ?? "", "<p>HTML 正文</p>")
        let attachments = parsed.attachments()
        @Assert(attachments.size, 1)
        let bytes = readAllBytes((attachments[0].source() ?? MemoryBodySource(Array<Byte>())).open())
        @Assert(bytes.size, payload.size)
        @Assert(bytes[3], payload[3])
    }

    @TestCase
    public func writesBccAsIs(): Unit {
        let message = MailMessage.builder()
            .from("a@x.com")
            .to("b@y.com")
            .bcc("hidden@example.com")
            .text("hi")
            .build()
        let out = BufferOutput()
        MimeWriter(out).write(message)
        @Assert(out.text().contains("Bcc: hidden@example.com"), true)
    }

    @TestCase
    public func headersFoldWithinLimit(): Unit {
        let longSubject = String(Array<Rune>(120, repeat: r'x'))
        let headers = HeaderMap()
        headers.set("Subject", longSubject)
        let out = BufferOutput()
        MimeWriter(out).write(MailMessage(MimePart(headers: headers, body: PartBody.Text("hi"))))
        for (line in out.text().split("\r\n")) {
            @Assert(line.size <= 78, true)
        }
    }

    @TestCase
    public func forceSevenBitConflictsWithNonAscii(): Unit {
        let headers = HeaderMap()
        headers.set("Content-Type", "text/plain; charset=utf-8")
        let message = MailMessage(
            MimePart(headers: headers, body: PartBody.Text("中文"))
        )
        var caught = false
        try {
            MimeWriter(
                BufferOutput(),
                options: MimeWriteOptions(forceEncoding: TransferEncoding.SevenBit)
            ).write(message)
        } catch (_: MimeException) {
            caught = true
        }
        @Assert(caught, true)
    }

    @TestCase
    public func utf8HeadersWritesRawBytes(): Unit {
        let headers = HeaderMap()
        headers.set("Subject", "中文主题")
        headers.set("Content-Type", "text/plain; charset=utf-8")
        let message = MailMessage(MimePart(headers: headers, body: PartBody.Text("hi")))
        let raw = BufferOutput()
        MimeWriter(raw, options: MimeWriteOptions(utf8Headers: true)).write(message)
        @Assert(raw.text().contains("=?utf-8?"), false)
        @Assert(MimeParser.parse(BufferInput(raw.bytes())).subject() ?? "", "中文主题")

        let encoded = BufferOutput()
        MimeWriter(encoded).write(message)
        @Assert(encoded.text().toAsciiLower().contains("=?utf-8?"), true)
        @Assert(MimeParser.parse(BufferInput(encoded.bytes())).subject() ?? "", "中文主题")
    }

    @TestCase
    public func bodyUsesQuotedPrintableWhenNo8BitMime(): Unit {
        let headers = HeaderMap()
        headers.set("Content-Type", "text/plain; charset=utf-8")
        let message = MailMessage(MimePart(headers: headers, body: PartBody.Text("this body is mostly plain ascii text with one 中文 word")))
        let out = BufferOutput()
        MimeWriter(out).write(message)
        @Assert(out.text().contains("Content-Transfer-Encoding: quoted-printable"), true)
        @Assert(hasEightBit(out.bytes()), false)
    }

    @TestCase
    public func bodyUsesEightBitWhenAllowed(): Unit {
        let headers = HeaderMap()
        headers.set("Content-Type", "text/plain; charset=utf-8")
        let message = MailMessage(MimePart(headers: headers, body: PartBody.Text("this body is mostly plain ascii text with one 中文 word")))
        let out = BufferOutput()
        MimeWriter(out, options: MimeWriteOptions(allow8Bit: true)).write(message)
        @Assert(out.text().contains("Content-Transfer-Encoding: 8bit"), true)
    }

    private func hasEightBit(bytes: Array<Byte>): Bool {
        for (b in bytes) {
            if (b > 126) {
                return true
            }
        }
        false
    }
}

@Test
public class MimeParser_test {
    @TestCase
    public func parsesNestedMultipart(): Unit {
        let raw = "From: a@x.com\r\n" +
            "Content-Type: multipart/mixed; boundary=outer\r\n" +
            "\r\n" +
            "--outer\r\n" +
            "Content-Type: multipart/alternative; boundary=inner\r\n" +
            "\r\n" +
            "--inner\r\n" +
            "Content-Type: text/plain; charset=utf-8\r\n" +
            "\r\n" +
            "plain body\r\n" +
            "--inner\r\n" +
            "Content-Type: text/html; charset=utf-8\r\n" +
            "\r\n" +
            "<p>html body</p>\r\n" +
            "--inner--\r\n" +
            "--outer--\r\n"
        let message = MimeParser.parse(BufferInput(raw.toArray()))
        @Assert(message.text() ?? "", "plain body")
        @Assert(message.html() ?? "", "<p>html body</p>")
    }

    @TestCase
    public func oneByteStreamMatchesBulkParse(): Unit {
        let raw = "Subject: hi\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nbody text"
        let bulk = MimeParser.parse(BufferInput(raw.toArray()))
        let slow = MimeParser.parse(OneByteInput(raw.toArray()))
        @Assert(slow.subject() ?? "", bulk.subject() ?? "")
        @Assert(slow.text() ?? "", "body text")
    }

    @TestCase
    public func missingClosingBoundaryIsLenient(): Unit {
        let raw = "Content-Type: multipart/mixed; boundary=b\r\n\r\n--b\r\n\r\ntail"
        let message = MimeParser.parse(BufferInput(raw.toArray()))
        @Assert(message.root.isMultipart(), true)
        @Assert(message.text() ?? "", "tail")
    }

    @TestCase
    public func depthLimitIsEnforced(): Unit {
        var raw = ""
        let depth = 40
        for (i in 0..depth) {
            raw = raw + "Content-Type: multipart/mixed; boundary=b${i}\r\n\r\n--b${i}\r\n"
        }
        raw = raw + "\r\n"
        var closeIndex = depth - 1
        while (closeIndex >= 0) {
            raw = raw + "--b${closeIndex}--\r\n"
            closeIndex -= 1
        }
        var caught = false
        try {
            MimeParser.parse(BufferInput(raw.toArray()))
        } catch (e: MailLimitException) {
            caught = e.kind.toString() == "Depth"
        }
        @Assert(caught, true)
    }

    @TestCase
    public func quotedPrintableBodyIsDecoded(): Unit {
        let raw = "Content-Type: text/plain; charset=utf-8\r\n" +
            "Content-Transfer-Encoding: quoted-printable\r\n\r\n=E4=B8=AD=E6=96=87"
        @Assert(MimeParser.parse(BufferInput(raw.toArray())).text() ?? "", "中文")
    }

    @TestCase
    public func base64BodyIsDecoded(): Unit {
        let raw = "Content-Type: text/plain; charset=utf-8\r\n" +
            "Content-Transfer-Encoding: base64\r\n\r\n5Lit5paH"
        @Assert(MimeParser.parse(BufferInput(raw.toArray())).text() ?? "", "中文")
    }

    @TestCase
    public func bareUtf8HeaderIsPreserved(): Unit {
        let raw = "Subject: 中文主题\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nx"
        @Assert(MimeParser.parse(BufferInput(raw.toArray())).subject() ?? "", "中文主题")
    }

    @TestCase
    public func embeddedMessageIsParsed(): Unit {
        let inner = "Subject: inner\r\nContent-Type: text/plain\r\n\r\ninner body"
        let raw = "Content-Type: message/rfc822\r\n\r\n${inner}"
        let message = MimeParser.parse(BufferInput(raw.toArray()))
        var embeddedSubject = ""
        match (message.root.body) {
            case PartBody.Embedded(innerMessage) => embeddedSubject = innerMessage.subject() ?? ""
            case _ => ()
        }
        @Assert(embeddedSubject, "inner")
    }

    @TestCase
    public func gb2312BodyDeclaredButGbkEncodedIsDecoded(): Unit {
        // "中文" 的 GBK 字节，声明 gb2312（实为 GBK 超集）
        let bytes = ArrayList<Byte>()
        for (b in "Content-Type: text/plain; charset=gb2312\r\n\r\n".toArray()) {
            bytes.add(b)
        }
        for (b in [UInt8(0xd6), UInt8(0xd0), UInt8(0xce), UInt8(0xc4)]) {
            bytes.add(b)
        }
        let message = MimeParser.parse(BufferInput(bytes.toArray()))
        @Assert(message.text() ?? "", "中文")
        @Assert(message.root.charsetLossy, false)
    }

    @TestCase
    public func winmailDatIsKeptAsAttachment(): Unit {
        let raw = "Content-Type: multipart/mixed; boundary=b\r\n\r\n" +
            "--b\r\nContent-Type: application/ms-tnef; name=winmail.dat\r\n" +
            "Content-Disposition: attachment; filename=winmail.dat\r\n\r\n" +
            "TNEf\r\n--b--\r\n"
        let message = MimeParser.parse(BufferInput(raw.toArray()))
        @Assert(message.attachments().size, 1)
        @Assert(message.attachments()[0].contentType.mediaType, "application/ms-tnef")
    }

    @TestCase
    public func tenLevelNestingIsParsed(): Unit {
        var raw = "Content-Type: multipart/mixed; boundary=b0\r\n\r\n--b0\r\n"
        var level = 1
        while (level < 10) {
            raw = raw + "Content-Type: multipart/mixed; boundary=b${level}\r\n\r\n" +
                "--b${level}\r\n"
            level += 1
        }
        raw = raw + "Content-Type: text/plain\r\n\r\ndeep\r\n"
        var close = 9
        while (close >= 0) {
            raw = raw + "--b${close}--\r\n"
            close -= 1
        }
        let message = MimeParser.parse(BufferInput(raw.toArray()))
        @Assert(message.text() ?? "", "deep")
    }

    @TestCase
    public func largeAttachmentIsSpooled(): Unit {
        let payload = Array<Byte>(100 * 1024, repeat: b'A')
        let encoded = Base64Codec.encode(payload)
        let raw = "Content-Type: multipart/mixed; boundary=b\r\n\r\n" +
            "--b\r\nContent-Type: application/octet-stream\r\n" +
            "Content-Transfer-Encoding: base64\r\n\r\n" +
            encoded + "\r\n--b--\r\n"
        let message = MimeParser.parse(
            BufferInput(raw.toArray()),
            options: MimeParseOptions(spoolThreshold: 4096, spoolDir: None)
        )
        let parts = message.root.children()
        @Assert(parts.size, 1)
        match (parts[0].body) {
            case PartBody.Data(source) =>
                @Assert(source is FileBodySource, true)
                let bytes = readAllBytes(source.open())
                @Assert(bytes.size, payload.size)
            case _ => @Fail("大附件没有落盘")
        }
    }

    @TestCase
    public func walkSkipsPartButStillEnds(): Unit {
        let raw = "Content-Type: multipart/mixed; boundary=b\r\n\r\n" +
            "--b\r\nContent-Type: text/plain\r\n\r\nfirst\r\n" +
            "--b\r\nContent-Type: text/plain\r\n\r\nsecond\r\n--b--\r\n"
        let visitor = RecordingVisitor()
        MimeParser.walk(BufferInput(raw.toArray()), visitor)
        @Assert(visitor.events[0], "start:")
        @Assert(visitor.events.contains("end:1"), true)
        @Assert(visitor.events.contains("end:2"), true)
    }
}

func readAllBytes(input: InputStream): Array<Byte> {
    let out = ArrayList<Byte>()
    let buffer = Array<Byte>(8192, repeat: 0)
    while (true) {
        let n = input.read(buffer)
        if (n <= 0) {
            break
        }
        for (i in 0..n) {
            out.add(buffer[i])
        }
    }
    out.toArray()
}

class BufferInput <: InputStream {
    private let bytes: Array<Byte>
    private var pos = 0

    init(bytes: Array<Byte>) {
        this.bytes = bytes
    }

    public func read(buffer: Array<Byte>): Int64 {
        if (pos >= bytes.size) {
            return 0
        }
        var take = bytes.size - pos
        if (take > buffer.size) {
            take = buffer.size
        }
        for (i in 0..take) {
            buffer[i] = bytes[pos + i]
        }
        pos += take
        take
    }
}

class OneByteInput <: InputStream {
    private let bytes: Array<Byte>
    private var pos = 0

    init(bytes: Array<Byte>) {
        this.bytes = bytes
    }

    public func read(buffer: Array<Byte>): Int64 {
        if (pos >= bytes.size || buffer.size == 0) {
            return 0
        }
        buffer[0] = bytes[pos]
        pos += 1
        1
    }
}

class BufferOutput <: OutputStream {
    private let data = ArrayList<Byte>()

    public func write(buffer: Array<Byte>): Unit {
        for (b in buffer) {
            data.add(b)
        }
    }

    func bytes(): Array<Byte> {
        data.toArray()
    }

    func text(): String {
        String.fromUtf8(data.toArray())
    }
}

class RecordingVisitor <: MimeVisitor {
    let events = ArrayList<String>()

    public func onPartStart(path: String, headers: HeaderMap): MimeAction {
        events.add("start:${path}")
        MimeAction.Continue
    }

    public func onBodyData(path: String, data: Array<Byte>): MimeAction {
        events.add("body:${path}")
        MimeAction.Continue
    }

    public func onPartEnd(path: String): MimeAction {
        events.add("end:${path}")
        MimeAction.Continue
    }
}

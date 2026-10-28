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
package fountain::f_email.model

import std.unittest.*
import std.unittest.testmacro.*

@Test
public class Address_test {
    @TestCase
    public func parsesGroupSyntax(): Unit {
        let list = AddressList.parse("Team: a@x.com, b@y.com;")
        @Assert(list.size, 2)
        @Assert(list.toArray()[0].address, "a@x.com")
        @Assert(list.toArray()[1].address, "b@y.com")
    }

    @TestCase
    public func quotedDisplayNameRoundTrips(): Unit {
        let address = EmailAddress.parse("\"Doe, John\" <j@example.com>")
        @Assert(address.name ?? "", "Doe, John")
        let text = address.toString()
        @Assert(text, "\"Doe, John\" <j@example.com>")
        @Assert(EmailAddress.parse(text).address, "j@example.com")
    }

    @TestCase
    public func commentBecomesDisplayName(): Unit {
        let address = EmailAddress.parse("user@example.com (work)")
        @Assert(address.address, "user@example.com")
        @Assert(address.name ?? "", "work")
    }

    @TestCase
    public func encodedDisplayNameIsDecoded(): Unit {
        let address = EmailAddress.parse("=?UTF-8?B?5byg5LiJ?= <z@example.com>")
        @Assert(address.name ?? "", "张三")
        @Assert(address.toString().contains("=?UTF-8?"), true)
    }

    @TestCase
    public func domainLiteralAndQuotedLocalPart(): Unit {
        @Assert(EmailAddress.parse("user@[192.0.2.1]").address, "user@[192.0.2.1]")
        @Assert(EmailAddress.parse("\"john doe\"@example.com").address, "\"john doe\"@example.com")
    }

    @TestCase
    public func obsoleteRouteIsAcceptedOnParse(): Unit {
        let address = EmailAddress.parse("<@a.com,@b.com:user@host.com>")
        @Assert(address.address, "user@host.com")
    }

    @TestCase
    public func addressInjectionIsRejected(): Unit {
        var caught = false
        try {
            EmailAddress("a@b>\r\nRCPT TO:<c@d")
        } catch (_: MailProtocolException) {
            caught = true
        }
        @Assert(caught, true)
    }

    @TestCase
    public func obsoleteRouteIsRejectedOnGenerate(): Unit {
        var caught = false
        try {
            EmailAddress("@a.com:user@host.com")
        } catch (_: MailProtocolException) {
            caught = true
        }
        @Assert(caught, true)
    }

    @TestCase
    public func multipleRecipientsWithCommas(): Unit {
        let list = AddressList.parse("a@x.com, \"B, C\" <b@y.com>")
        @Assert(list.size, 2)
        @Assert(list.toArray()[1].address, "b@y.com")
    }
}

@Test
public class MailMessage_test {
    @TestCase
    public func builderMakesAlternativeWithAttachments(): Unit {
        let message = MailMessage.builder()
            .from("a@x.com")
            .to("b@y.com")
            .subject("测试")
            .text("plain")
            .html("<b>html</b>")
            .attach("a.bin", MemoryBodySource([UInt8(1), UInt8(2), UInt8(3)]))
            .build()
        @Assert(message.contentType().mediaType, "multipart/mixed")
        @Assert(message.text() ?? "", "plain")
        @Assert(message.html() ?? "", "<b>html</b>")
        @Assert(message.attachments().size, 1)
        @Assert(message.headers.get("MIME-Version") ?? "", "1.0")
    }

    @TestCase
    public func headerOnlyMessageHasNoText(): Unit {
        let message = MailMessage.builder().from("a@x.com").to("b@y.com").build()
        @Assert(message.text().isNone(), true)
        @Assert(message.html().isNone(), true)
    }

    @TestCase
    public func inlineImageIsNotAttachment(): Unit {
        let headers = HeaderMap()
        headers.set("Content-Type", "multipart/mixed; boundary=b")
        let imageHeaders = HeaderMap()
        imageHeaders.set("Content-Type", "image/png")
        imageHeaders.set("Content-Disposition", "inline")
        let textHeaders = HeaderMap()
        textHeaders.set("Content-Type", "text/plain; charset=utf-8")
        let image = MimePart(headers: imageHeaders, body: PartBody.Data(MemoryBodySource(Array<Byte>())))
        let text = MimePart(headers: textHeaders, body: PartBody.Text("hi"))
        let root = MimePart(
            headers: headers,
            body: PartBody.Parts(Multipart("b", parts: [text, image]))
        )
        let message = MailMessage(root)
        @Assert(message.attachments().size, 0)
        @Assert(message.text() ?? "", "hi")
        @Assert(message.root.children().size, 2)
    }

    @TestCase
    public func htmlOnlyMessageReturnsNoText(): Unit {
        let headers = HeaderMap()
        headers.set("Content-Type", "text/html; charset=utf-8")
        let message = MailMessage(MimePart(headers: headers, body: PartBody.Text("<p>x</p>")))
        @Assert(message.text().isNone(), true)
        @Assert(message.html() ?? "", "<p>x</p>")
    }
}

@Test
public class Envelope_test {
    @TestCase
    public func resentTakesPriority(): Unit {
        let message = MailMessage.builder()
            .from("a@x.com")
            .to("b@y.com")
            .header("Resent-From", "c@z.com")
            .header("Resent-To", "d@w.com")
            .build()
        let envelope = Envelope.fromMessage(message)
        @Assert(envelope.from, "c@z.com")
        @Assert(envelope.recipients[0], "d@w.com")
    }

    @TestCase
    public func missingRecipientsThrows(): Unit {
        let message = MailMessage.builder().from("a@x.com").build()
        var caught = false
        try {
            Envelope.fromMessage(message)
        } catch (_: MailProtocolException) {
            caught = true
        }
        @Assert(caught, true)
    }

    @TestCase
    public func missingFromThrows(): Unit {
        let message = MailMessage.builder().to("b@y.com").build()
        var caught = false
        try {
            Envelope.fromMessage(message)
        } catch (_: MailProtocolException) {
            caught = true
        }
        @Assert(caught, true)
    }
}

@Test
public class BodySource_test {
    @TestCase
    public func streamSourceOpensOnlyOnce(): Unit {
        let source = StreamBodySource(ArrayInput("hello".toArray()))
        @Assert(source.reusable, false)
        let first = MimePart.readAll(source.open())
        @Assert(String.fromUtf8(first), "hello")
        var caught = false
        try {
            source.open()
        } catch (_: MimeException) {
            caught = true
        }
        @Assert(caught, true)
    }

    @TestCase
    public func memorySourceIsReusable(): Unit {
        let source = MemoryBodySource("abc".toArray())
        @Assert(String.fromUtf8(MimePart.readAll(source.open())), "abc")
        @Assert(String.fromUtf8(MimePart.readAll(source.open())), "abc")
        @Assert(source.size, 3)
    }
}

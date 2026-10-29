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
public class ContentType_test {
    @TestCase
    public func semicolonInsideQuotesIsNotASeparator(): Unit {
        let ct = ContentType.parse("application/octet-stream; name=\"a;b.bin\"")
        @Assert(ct.typeName, "application")
        @Assert(ct.subtype, "octet-stream")
        @Assert(ct.name() ?? "", "a;b.bin")
    }

    @TestCase
    public func missingHeaderDefaultsToPlainText(): Unit {
        let ct = ContentType.defaultText()
        @Assert(ct.mediaType, "text/plain")
        @Assert(ct.charsetName() ?? "", "us-ascii")
        @Assert((ct.charset() ?? CharsetResolver.resolve(None)).toString(), "UTF-8")
    }

    @TestCase
    public func typeIsLowercased(): Unit {
        let ct = ContentType.parse("TEXT/HTML; Charset=UTF-8")
        @Assert(ct.mediaType, "text/html")
        @Assert(ct.charsetName() ?? "", "UTF-8")
    }

    @TestCase
    public func skipsCommentsBetweenParameters(): Unit {
        let ct = ContentType.parse("text/plain; (a note) charset=utf-8; format=flowed")
        @Assert(ct.charsetName() ?? "", "utf-8")
        @Assert(ct.parameters.get("format") ?? "", "flowed")
    }

    @TestCase
    public func parsesRfc2231SingleParameter(): Unit {
        let ct = ContentType.parse("application/pdf; filename*=UTF-8''%E4%B8%AD%E6%96%87.pdf")
        @Assert(ct.parameters.get("filename") ?? "", "中文.pdf")
    }

    @TestCase
    public func parsesRfc2231Continuation(): Unit {
        let ct = ContentType.parse(
            "application/pdf; filename*0*=UTF-8''%E4%B8%AD; filename*1*=%E6%96%87.pdf"
        )
        @Assert(ct.parameters.get("filename") ?? "", "中文.pdf")
    }

    @TestCase
    public func parsesLegacyRfc2047Parameter(): Unit {
        let ct = ContentType.parse("application/pdf; filename=\"=?UTF-8?B?5Lit5paHLnBkZg==?=\"")
        @Assert(ct.parameters.get("filename") ?? "", "中文.pdf")
    }

    @TestCase
    public func generatesRfc2231ForNonAscii(): Unit {
        let params = MimeParameters()
        params.add("filename", "中文.pdf")
        let disposition = ContentDisposition("attachment", parameters: params)
        let text = disposition.toString()
        @Assert(text.contains("filename*=UTF-8''"), true)
        @Assert(text.contains("=?"), false)
        @Assert(ContentDisposition.parse(text).filename() ?? "", "中文.pdf")
    }

    @TestCase
    public func generatesQuotedAsciiParameter(): Unit {
        let params = MimeParameters()
        params.add("filename", "a b.txt")
        let text = ContentType("application/octet-stream", parameters: params).toString()
        @Assert(text.contains("filename=\"a b.txt\""), true)
    }

    @TestCase
    public func contentTypeToStringRoundTrips(): Unit {
        let ct = ContentType.parse("Multipart/Mixed; boundary=\"=_fountain_abc\"; charset=utf-8")
        let again = ContentType.parse(ct.toString())
        @Assert(again.mediaType, "multipart/mixed")
        @Assert(again.boundary() ?? "", "=_fountain_abc")
        @Assert(again.charsetName() ?? "", "utf-8")
    }

    @TestCase
    public func dispositionAttachmentAndInline(): Unit {
        @Assert(ContentDisposition.parse("attachment; filename=x.bin").isAttachment, true)
        @Assert(ContentDisposition.parse("inline").isInline, true)
    }
}

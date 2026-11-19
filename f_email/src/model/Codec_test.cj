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

import std.collection.ArrayList
import std.io.InputStream
import std.unittest.*
import std.unittest.testmacro.*

@Test
public class Codec_test {
    @TestCase
    public func base64RoundTrip(): Unit {
        let data = "Hello, 世界!".toArray()
        let encoded = Base64Codec.encodeUnwrapped(data)
        @Assert(String.fromUtf8(Base64Codec.decode(encoded)), "Hello, 世界!")
    }

    @TestCase
    public func base64DecodeWithoutPadding(): Unit {
        @Assert(String.fromUtf8(Base64Codec.decode("SGVsbG8")), "Hello")
    }

    @TestCase
    public func base64DecodeIgnoresWhitespace(): Unit {
        @Assert(String.fromUtf8(Base64Codec.decode("SGVs bG8=\r\n")), "Hello")
    }

    @TestCase
    public func base64LenientKeepsGoingOnInvalidChars(): Unit {
        @Assert(String.fromUtf8(Base64Codec.decode("SGVs*bG8=")), "Hello")
    }

    @TestCase
    public func base64StrictRejectsInvalidChars(): Unit {
        var caught = false
        try {
            Base64Codec.decode("SGVs*bG8=", strict: true)
        } catch (_: MimeException) {
            caught = true
        }
        @Assert(caught, true)
    }

    @TestCase
    public func base64EncodeWrapsAt76(): Unit {
        let data = Array<Byte>(120, repeat: b'a')
        let encoded = Base64Codec.encode(data)
        let lines = encoded.split("\r\n")
        @Assert(lines.size > 1, true)
        for (line in lines) {
            @Assert(line.size <= 76, true)
        }
        @Assert(String.fromUtf8(Base64Codec.decode(encoded)), String.fromUtf8(data))
    }

    @TestCase
    public func base64StreamingDecoderWithOneByteChunks(): Unit {
        let payload = Base64Codec.encode("流式解码测试".toArray())
        let decoder = Base64Decoder(OneByteInput(payload.toArray()))
        @Assert(readAll(decoder), "流式解码测试")
    }

    @TestCase
    public func qpEncodesTrailingSpace(): Unit {
        @Assert(QuotedPrintable.encode("abc ".toArray()), "abc=20")
    }

    @TestCase
    public func qpEncodesEqualsAndNonAscii(): Unit {
        let encoded = QuotedPrintable.encode("a=b中".toArray())
        @Assert(encoded.contains("=3D"), true)
        @Assert(encoded.contains("=E4=B8=AD"), true)
        @Assert(String.fromUtf8(QuotedPrintable.decode(encoded)), "a=b中")
    }

    @TestCase
    public func qpSoftBreakKeepsContent(): Unit {
        let text = String(Array<Rune>(200, repeat: r'x'))
        let encoded = QuotedPrintable.encode(text.toArray())
        for (line in encoded.split("\r\n")) {
            @Assert(line.size <= 76, true)
        }
        @Assert(String.fromUtf8(QuotedPrintable.decode(encoded)), text)
    }

    @TestCase
    public func qpSoftBreakAcrossChunks(): Unit {
        let decoder = QuotedPrintableDecoder(OneByteInput("abc=3Ddef=4".toArray()))
        // 末尾悬空的 "=4"：宽松模式下原样保留
        @Assert(readAll(decoder), "abc=def=4")
    }

    @TestCase
    public func qpDecodesSoftLineBreak(): Unit {
        @Assert(String.fromUtf8(QuotedPrintable.decode("abc=\r\ndef")), "abcdef")
    }

    @TestCase
    public func encodedWordAdjacentSpacesDropped(): Unit {
        @Assert(EncodedWord.decode("=?UTF-8?B?5Lit?= =?UTF-8?B?5paH?="), "中文")
    }

    @TestCase
    public func encodedWordMixedKeepsPlainWhitespace(): Unit {
        @Assert(EncodedWord.decode("hello =?UTF-8?Q?world?= again"), "hello world again")
    }

    @TestCase
    public func encodedWordQUnderscoreIsSpace(): Unit {
        @Assert(EncodedWord.decode("=?UTF-8?Q?a_b?="), "a b")
    }

    @TestCase
    public func encodedWordUnknownCharsetFallsBack(): Unit {
        @Assert(EncodedWord.decode("=?x-unknown-42?B?SGVsbG8=?="), "Hello")
    }

    @TestCase
    public func encodedWordEncodeLeavesAsciiAlone(): Unit {
        @Assert(EncodedWord.encode("plain ascii"), "plain ascii")
    }

    @TestCase
    public func encodedWordEncodeSplitsOnCharacterBoundary(): Unit {
        let text = String(Array<Rune>(30, repeat: r'中'))
        let encoded = EncodedWord.encode(text)
        @Assert(encoded.contains("=?UTF-8?"), true)
        @Assert(EncodedWord.decode(encoded), text)
        for (word in encoded.split(" ")) {
            @Assert(word.size <= 75, true)
        }
    }

    @TestCase
    public func charsetResolverFallsBackForUnknownName(): Unit {
        let decoded = CharsetResolver.decode("中文".toArray(), Some("x-unknown-42"))
        @Assert(decoded.text, "中文")
        @Assert(decoded.lossy, false)
    }

    @TestCase
    public func charsetResolverTreatsGb2312AsGbk(): Unit {
        let gbk: Array<Byte> = [0xd6, 0xd0, 0xce, 0xc4]
        let decoded = CharsetResolver.decode(gbk, Some("gb2312"))
        @Assert(decoded.text, "中文")
    }

    private func readAll(decoder: InputStream): String {
        let out = Array<Byte>(7, repeat: 0)
        let bytes = ArrayList<Byte>()
        while (true) {
            let n = decoder.read(out)
            if (n <= 0) {
                break
            }
            for (i in 0..n) {
                bytes.add(out[i])
            }
        }
        String.fromUtf8(bytes.toArray())
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

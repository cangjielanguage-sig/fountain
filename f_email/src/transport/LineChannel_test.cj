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
package fountain::f_email.transport

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_email.{LimitKind, MailIoException, MailLimitException, MailProtocolException}

@Test
public class LineChannel_test {
    @TestCase
    public func readsCrlfLine(): Unit {
        let out = CollectOutput()
        let channel = LineChannel(FixedInput("220 ready\r\n"), out)
        let line = channel.readLine()
        @Assert(String.fromUtf8(line ?? Array<Byte>()), "220 ready")
    }

    @TestCase
    public func acceptsBareLf(): Unit {
        let out = CollectOutput()
        let trace = RecordingTrace()
        let channel = LineChannel(FixedInput("250 OK\n"), out, trace: trace)
        @Assert(String.fromUtf8(channel.readLine() ?? Array<Byte>()), "250 OK")
        @Assert(channel.isClosed(), false)
    }

    @TestCase
    public func rejectsInjection(): Unit {
        let out = CollectOutput()
        let channel = LineChannel(FixedInput(""), out)
        var caught = false
        try {
            channel.writeLine("AUTH PLAIN xxx\r\nRCPT TO:<evil@example.com>")
        } catch (_: MailProtocolException) {
            caught = true
        }
        @Assert(caught, true)
        @Assert(out.bytes().size, 0)
    }

    @TestCase
    public func overlongLineClosesConnection(): Unit {
        let out = CollectOutput()
        let channel = LineChannel(FixedInput("0123456789\r\n"), out, maxLine: 4)
        var kind = LimitKind.Header
        try {
            channel.readLine()
        } catch (e: MailLimitException) {
            kind = e.kind
        }
        @Assert(kind.toString(), "Line")
        @Assert(channel.isClosed(), true)
    }

    @TestCase
    public func readExactConsumesLineBufferLeftover(): Unit {
        let out = CollectOutput()
        let channel = LineChannel(FixedInput("A1 OK {5}\r\nHELLOrest"), out)
        @Assert(String.fromUtf8(channel.readLine() ?? Array<Byte>()), "A1 OK {5}")
        @Assert(String.fromUtf8(channel.readExact(5)), "HELLO")
        @Assert(String.fromUtf8(channel.readLine() ?? Array<Byte>()), "rest")
    }

    @TestCase
    public func oneByteAtATime(): Unit {
        let out = CollectOutput()
        let channel = LineChannel(FixedInput("A1 OK {5}\r\nHELLOrest\r\n", chunk: 1), out, buffered: false)
        @Assert(String.fromUtf8(channel.readLine() ?? Array<Byte>()), "A1 OK {5}")
        @Assert(String.fromUtf8(channel.readExact(5)), "HELLO")
        @Assert(String.fromUtf8(channel.readLine() ?? Array<Byte>()), "rest")
    }

    @TestCase
    public func eofReturnsNoneWhenEmpty(): Unit {
        let out = CollectOutput()
        let channel = LineChannel(FixedInput(""), out)
        @Assert(channel.readLine().isNone(), true)
    }

    @TestCase
    public func eofReturnsPartialLine(): Unit {
        let out = CollectOutput()
        let channel = LineChannel(FixedInput("partial"), out)
        @Assert(String.fromUtf8(channel.readLine() ?? Array<Byte>()), "partial")
        @Assert(channel.readLine().isNone(), true)
    }

    @TestCase
    public func replacedChannelFails(): Unit {
        let out = CollectOutput()
        let channel = LineChannel(FixedInput("220 ready\r\n"), out)
        channel.invalidate()
        var caught = false
        try {
            channel.readLine()
        } catch (e: MailProtocolException) {
            caught = e.message.contains("channel replaced by STARTTLS")
        }
        @Assert(caught, true)
    }

    @TestCase
    public func closeIsIdempotent(): Unit {
        let out = CollectOutput()
        let channel = LineChannel(FixedInput(""), out)
        channel.close()
        channel.close()
        @Assert(channel.isClosed(), true)
    }

    @TestCase
    public func tracesRedactedAuthLine(): Unit {
        let out = CollectOutput()
        let trace = RecordingTrace()
        let channel = LineChannel(FixedInput(""), out, trace: trace)
        channel.writeLine("AUTH PLAIN AHVzZXIAcGFzcw==")
        let lines = trace.textLines()
        @Assert(lines.size, 1)
        @Assert(lines[0], "AUTH PLAIN <redacted>")
    }

    @TestCase
    public func sensitiveModeRedactsWholeLine(): Unit {
        let out = CollectOutput()
        let trace = RecordingTrace()
        let channel = LineChannel(FixedInput(""), out, trace: trace)
        channel.beginSensitive()
        channel.writeLine("AHVzZXIAcGFzcw==")
        channel.endSensitive()
        @Assert(trace.textLines()[0], "<redacted>")
    }

}

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

@Test
public class DotStuff_test {
    @TestCase
    public func stuffsLeadingDot(): Unit {
        let out = CollectOutput()
        let writer = DotStuffWriter(out)
        writer.write(".hello\r\n".toArray())
        writer.finish()
        @Assert(out.text(), "..hello\r\n.\r\n")
    }

    @TestCase
    public func emptyBodyWritesOnlyTerminator(): Unit {
        let out = CollectOutput()
        let writer = DotStuffWriter(out)
        writer.finish()
        @Assert(out.text(), ".\r\n")
    }

    @TestCase
    public func addsCrlfBeforeTerminator(): Unit {
        let out = CollectOutput()
        let writer = DotStuffWriter(out)
        writer.write("abc".toArray())
        writer.finish()
        @Assert(out.text(), "abc\r\n.\r\n")
    }

    @TestCase
    public func normalizesBareLfAndCr(): Unit {
        let out = CollectOutput()
        let writer = DotStuffWriter(out)
        writer.write("a\nb\rc\r\nd".toArray())
        writer.finish()
        @Assert(out.text(), "a\r\nb\r\nc\r\nd\r\n.\r\n")
    }

    /** 跨块边界：一次 write 以 `.` 结束，下一次以换行和 `.abc` 开始。 */
    @TestCase
    public func dotAcrossChunkBoundary(): Unit {
        let out = CollectOutput()
        let writer = DotStuffWriter(out)
        writer.write("x.".toArray())
        writer.write("\n.abc".toArray())
        writer.finish()
        @Assert(out.text(), "x.\r\n..abc\r\n.\r\n")
    }

    @TestCase
    public func unstuffRestoresOriginal(): Unit {
        let out = CollectOutput()
        let writer = DotStuffWriter(out)
        let original = ".start\n..two\nend.\n."
        writer.write(original.toArray())
        writer.finish()

        let reader = DotUnstuffReader(FixedInput(out.bytes()))
        @Assert(readAllText(reader), ".start\r\n..two\r\nend.\r\n.\r\n")
    }

    @TestCase
    public func unstuffWithOneByteChunks(): Unit {
        let out = CollectOutput()
        let writer = DotStuffWriter(out)
        let original = "line1\r\n.dot line\r\n..two dots\r\nlast\r\n"
        writer.write(original.toArray())
        writer.finish()

        let reader = DotUnstuffReader(FixedInput(out.bytes(), chunk: 1))
        @Assert(readAllText(reader), original)
    }

    @TestCase
    public func unstuffStopsAtSingleDot(): Unit {
        let reader = DotUnstuffReader(FixedInput("a\r\n.\r\ntrailing"))
        @Assert(readAllText(reader), "a\r\n")
    }

    /** 正文里一行 `..` 还原为 `.`，而传输层的 `..`（原始为 `.`）不会终止读取。 */
    @TestCase
    public func unstuffDotDotLine(): Unit {
        let reader = DotUnstuffReader(FixedInput("..\r\n...\r\n.\r\n"))
        @Assert(readAllText(reader), ".\r\n..\r\n")
    }

    private func readAllText(reader: DotUnstuffReader): String {
        let out = CollectOutput()
        let buf = Array<Byte>(7, repeat: 0)
        while (true) {
            let n = reader.read(buf)
            if (n <= 0) {
                break
            }
            for (i in 0..n) {
                out.write([buf[i]])
            }
        }
        out.text()
    }
}

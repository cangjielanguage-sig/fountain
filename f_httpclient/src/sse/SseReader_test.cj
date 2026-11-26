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
package fountain::f_httpclient.sse

import std.collection.ArrayList
import std.io.InputStream
import std.time.MonoTime
import std.unittest.*
import std.unittest.testmacro.*

/** 忙等代替 sleep：测试里不依赖 std 的 sleep 版本差异 */
func busyWait(d: Duration): Unit {
    let start = MonoTime.now()
    while(MonoTime.now() - start < d){}
}

/** 可按块喂数据的假流：每块带一个延迟，用来验证增量与超时 */
class ChunkStream <: InputStream {
    ChunkStream(private let chunks: ArrayList<(Duration, String)>) {}
    private var index: Int64 = 0
    public func read(buffer: Array<Byte>): Int64 {
        if(index >= chunks.size){
            return 0
        }
        let chunk = chunks[index]
        index++
        if(chunk[0] > Duration.Zero){
            busyWait(chunk[0])
        }
        let bytes = chunk[1].toArray()
        let n = if(bytes.size < buffer.size){ bytes.size } else { buffer.size }
        for(i in 0 .. n){
            buffer[i] = bytes[i]
        }
        n
    }
}

func streamOf(text: String): ChunkStream {
    ChunkStream(ArrayList<(Duration, String)>([(Duration.Zero, text)]))
}

@Test
public class SseReaderTest {

    @TestCase
    func testTwoEventsThenEnd(): Unit {
        let reader = SseReader(streamOf('data: a\n\ndata: b\n\n'))
        @Expect(reader.next()?.data ?? '', 'a')
        @Expect(reader.next()?.data ?? '', 'b')
        @Expect(reader.next().isNone(), true)
    }

    @TestCase
    func testCrlf(): Unit {
        let reader = SseReader(streamOf('data: a\r\ndata: b\r\n\r\n'))
        @Expect(reader.next()?.data ?? '', 'a\nb')
    }

    @TestCase
    func testCommentAndFields(): Unit {
        let reader = SseReader(streamOf(': ping\nevent: done\nid: 42\ndata: hello\nretry: 3000\n\n'))
        let event = reader.next().getOrThrow()
        @Expect(event.event, 'done')
        @Expect(event.id, '42')
        @Expect(event.data, 'hello')
        @Expect(event.retry, 3000)
    }

    @TestCase
    func testMultiLineDataKeepsLeadingSpaceRule(): Unit {
        // 只去掉一个前导空格：'data: x' 的值是 'x'，'data:x' 的值也是 'x'
        let reader = SseReader(streamOf('data: line1\ndata:line2\n\n'))
        @Expect(reader.next()?.data ?? '', 'line1\nline2')
    }

    @TestCase
    func testLongLine(): Unit {
        let reader = SseReader(streamOf('data: 0123456789\n\n'), maxLineBytes: 8)
        var thrown = false
        try{
            reader.next()
        }catch(e: SseLineTooLongException){
            thrown = true
        }
        @Expect(thrown, true)
    }

    @TestCase
    func testIncrementalFirstEventBeforeSecondWrite(): Unit {
        let reader = SseReader(ChunkStream(ArrayList<(Duration, String)>([
            (Duration.Zero, 'data: first\n\n'),
            (Duration.millisecond * 200, 'data: second\n\n')
        ])))
        let start = MonoTime.now()
        let first = reader.next()
        let elapsed = MonoTime.now() - start
        @Expect(first?.data ?? '', 'first')
        @Expect(elapsed < Duration.millisecond * 150, true)
    }

    @TestCase
    func testIdleTimeout(): Unit {
        let reader = SseReader(ChunkStream(ArrayList<(Duration, String)>([
            (Duration.Zero, 'data: a\n'),
            (Duration.millisecond * 60, '\n')
        ])), idleTimeout: Duration.millisecond * 10)
        @Expect(reader.next()?.data ?? '', 'a')
        var thrown = false
        try{
            reader.next()
        }catch(e: SseTimeoutException){
            thrown = true
        }
        @Expect(thrown, true)
    }

    @TestCase
    func testCloseThenNextIsNone(): Unit {
        let reader = SseReader(streamOf('data: a\n\n'))
        reader.close()
        @Expect(reader.next().isNone(), true)
        @Expect(reader.isClosed(), true)
    }
}

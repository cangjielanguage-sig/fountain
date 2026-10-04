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
package fountain::f_pool

import std.io.{ByteBuffer, SeekPosition}
import std.unittest.*
import std.unittest.testmacro.*

@Test
class BytesListClearOnReturnTest {
    /**
     * 池项归还后必须被清空（clearOnReturning 生效）。
     * 若不清空，下一个借用者会把新消息直接追加在旧字节后面 —— 编码结果里混进上一条消息的字节、
     * 消息丢了命令字节、对端解码错位，最终表现为心跳拆链风暴（见 .autocode/bugs/bug-archived-on-20261004.md 六）。
     */
    @TestCase
    func returnedBufferMustBeEmpty(): Unit {
        let builder = BytesListOutputStream.builder(initSize: 1, minSize: 1, maxSize: 1, clearOnReturning: true)
        let first = builder.build().getOrThrow()
        first.write([1u8, 2u8, 3u8])
        first.release()

        let second = builder.build().getOrThrow()
        let sink = ByteBuffer()
        second.copy(to: sink, closeFromOnEnd: false, closeToOnEnd: false)
        sink.seek(SeekPosition.Begin(0))
        let out = Array<Byte>(8, repeat: 0u8)
        let n = sink.read(out)
        @Assert(n == 0)
    }
}

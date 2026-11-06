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
package fountain::f_xml

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.ArrayList

@Test
public class PrefixStream_test {
    /** 前缀与剩余拼成连续流，EOF 返回 0。 */
    @TestCase
    public func prefixThenRest(): Unit {
        let prefix: Array<Byte> = [0x3C, 0x61]
        let stream = PrefixStream(prefix, MemoryInputStream(">x</a>"))
        let out = ArrayList<Byte>()
        let buf = Array<Byte>(3, repeat: 0)
        while (true) {
            let n = stream.read(buf)
            if (n == 0) {
                break
            }
            for (i in 0..n) {
                out.add(buf[i])
            }
        }
        @Assert(String.fromUtf8(out.toArray()) == "<a>x</a>")
    }

    /** close() 关闭底层流一次。 */
    @TestCase
    public func closeClosesRest(): Unit {
        let rest = TrackingInputStream("abc")
        let stream = PrefixStream(Array<Byte>(0, repeat: 0), rest)
        stream.close()
        @Assert(rest.closeCount == 1)
    }

    /** 空前缀直接透传底层。 */
    @TestCase
    public func emptyPrefixPassesThrough(): Unit {
        let stream = PrefixStream(Array<Byte>(0, repeat: 0), MemoryInputStream("ab"))
        let buf = Array<Byte>(8, repeat: 0)
        @Assert(stream.read(buf) == 2)
        @Assert(buf[0] == 0x61 && buf[1] == 0x62)
        @Assert(stream.read(buf) == 0)
    }
}

/*
Copyright (c) 2026 WuJingrun（吴京润）

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain at the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
 */
package fountain::fmq.common

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.ArrayList
import std.env.{setVariable, removeVariable}
import std.io.{ByteBuffer, SeekPosition}
import fountain::f_protocol.default.Message as ProtocolMessage


@Test
public class ParseEnvListTest {
    @TestCase
    public func testEmptyStringReturnsEmpty(): Unit {
        let r = parseEnvList("")
        @Assert(r.size == 0)
    }

    @TestCase
    public func testSingleValue(): Unit {
        let r = parseEnvList("node1:7201")
        @Assert(r.size == 1)
        @Assert(r[0] == "node1:7201")
    }

    @TestCase
    public func testMultipleValues(): Unit {
        let r = parseEnvList("a:1,b:2,c:3")
        @Assert(r.size == 3)
        @Assert(r[0] == "a:1")
        @Assert(r[1] == "b:2")
        @Assert(r[2] == "c:3")
    }

    @TestCase
    public func testTrimsWhitespace(): Unit {
        let r = parseEnvList(" a , b , c ")
        @Assert(r.size == 3)
        @Assert(r[0] == "a")
        @Assert(r[1] == "b")
        @Assert(r[2] == "c")
    }

    @TestCase
    public func testFiltersEmptyItems(): Unit {
        let r = parseEnvList("a,,b, ,c,")
        @Assert(r.size == 3)
        @Assert(r[0] == "a")
        @Assert(r[1] == "b")
        @Assert(r[2] == "c")
    }

    @TestCase
    public func testCommaAtStart(): Unit {
        @Assert(parseEnvList(",a,b").size == 2)
    }

    @TestCase
    public func testCommaAtEnd(): Unit {
        @Assert(parseEnvList("a,b,").size == 2)
    }

    @TestCase
    public func testConsecutiveCommas(): Unit {
        @Assert(parseEnvList(",,a,,b,,").size == 2)
    }

    @TestCase
    public func testNoCommaReturnsSingle(): Unit {
        let r = parseEnvList("   spaced  ")
        @Assert(r.size == 1)
        @Assert(r[0] == "spaced")
    }
}

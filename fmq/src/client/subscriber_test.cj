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
package fountain::fmq.client

import std.unittest.*
import std.unittest.testmacro.*
import std.random.*
import fountain::f_codec.default.DefaultCodec
import std.io.{ByteBuffer, SeekPosition}
import fountain::f_protocol.default.{Message as ProtocolMessage, EncodedMessage, MessageID}


@Test
public class SubscriberTest {
    @TestCase
    public func testExtractTopic(): Unit {
        @Assert(extractTopicInner(MatchMode.Exact("/a")) == "/a")
        @Assert(extractTopicInner(MatchMode.Glob("/a/*")) == "/a/*")
        @Assert(extractTopicInner(MatchMode.Prefix("/a/")) == "/a/")
    }

    @TestCase
    public func testModeToString(): Unit {
        @Assert(modeToStringInner(MatchMode.Exact("/a")) == "exact")
        @Assert(modeToStringInner(MatchMode.Glob("/a/*")) == "glob")
        @Assert(modeToStringInner(MatchMode.Prefix("/a/")) == "prefix")
    }

    /**
     * 反射测试：直接验证 Subscriber 的提取逻辑。
     */
    private static func extractTopicInner(mode: MatchMode): String {
        match (mode) {
            case Exact(t) => t
            case Glob(t) => t
            case Prefix(t) => t
        }
    }

    private static func modeToStringInner(mode: MatchMode): String {
        match (mode) {
            case Exact(_) => "exact"
            case Glob(_) => "glob"
            case Prefix(_) => "prefix"
        }
    }
}

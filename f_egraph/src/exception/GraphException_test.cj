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
package fountain::f_egraph.exception

import std.unittest.*
import std.unittest.testmacro.*

/** `GraphException` 的四个构造器与 `message`/`causedBy` 透传。 */
@Test
class GraphException_test {
    /** 无参构造器的消息为空。 */
    @TestCase
    public func defaultConstructorHasEmptyMessage(): Unit {
        let e = GraphException()
        @Assert(e.message, "")
        @Expect(e.causedBy.isNone(), true)
    }

    /** 消息构造器原样保留消息。 */
    @TestCase
    public func messageConstructorKeepsMessage(): Unit {
        let e = GraphException("boom")
        @Assert(e.message, "boom")
        @Expect(e.causedBy.isNone(), true)
    }

    /** 原因构造器把原异常挂到 `causedBy`。 */
    @TestCase
    public func causeConstructorKeepsCause(): Unit {
        let cause = GraphException("inner")
        let e = GraphException(cause)
        @Expect(e.causedBy.isSome(), true)
        @Assert(e.causedBy.getOrThrow().message, "inner")
    }

    /** 消息 + 原因构造器同时保留两者。 */
    @TestCase
    public func messageAndCauseConstructorKeepsBoth(): Unit {
        let cause = GraphException("inner")
        let e = GraphException("outer", cause)
        @Assert(e.message, "outer")
        @Assert(e.causedBy.getOrThrow().message, "inner")
    }
}

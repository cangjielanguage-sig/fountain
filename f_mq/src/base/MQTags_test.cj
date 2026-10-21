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
package fountain::f_mq.base

import std.unittest.*
import std.unittest.testmacro.*

private func fill(n: Int64): String {
    let buf = StringBuilder()
    for (_ in 0..n) {
        buf.append("a")
    }
    buf.toString()
}

@Test
class MQTagsTest {
    @TestCase
    public func emptyListAndOrdinaryTagsAreValid(): Unit {
        @Assert(MQTags.isValid([]))
        @Assert(MQTags.isValid(["a", "b-c", "订单"]))
        @Assert(MQTags.isValid(Array<String>(64, repeat: "t")))
    }

    @TestCase
    public func emptyOrOversizedTagIsRejected(): Unit {
        @Assert(!MQTags.isValid([""]))
        @Assert(!MQTags.isValid([fill(129)]))
        @Assert(MQTags.isValid([fill(128)]))
    }

    @TestCase
    public func whitespaceAndControlCharsAreRejected(): Unit {
        @Assert(!MQTags.isValid(["a b"]))
        @Assert(!MQTags.isValid(["a\tb"]))
        @Assert(!MQTags.isValid(["a\nb"]))
    }

    @TestCase
    public func tooManyTagsAreRejected(): Unit {
        @Assert(!MQTags.isValid(Array<String>(65, repeat: "t")))
    }
}

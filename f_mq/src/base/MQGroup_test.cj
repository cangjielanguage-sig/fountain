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
class MQGroupTest {
    @TestCase
    public func defaultGroupIsValid(): Unit {
        @Assert(MQGroup.isValid(""))
    }

    @TestCase
    public func ordinaryNamesAreValid(): Unit {
        @Assert(MQGroup.isValid("grp1"))
        @Assert(MQGroup.isValid("order.create-v2"))
    }

    @TestCase
    public func whitespaceAndSeparatorsAreRejected(): Unit {
        for (name in ["g 1", "g\t1", "g:1", "g/1", "g\\1", "g%2F", ".g", "g."]) {
            @Assert(!MQGroup.isValid(name))
        }
    }

    /** Unicode 空白（NBSP/表意空格）与 DEL 也是非法字符，不能只看 ASCII 字节（R1-G12）。 */
    @TestCase
    public func unicodeWhitespaceAndControlAreRejected(): Unit {
        for (name in ["g\u{7F}", "g\u{00A0}", "g\u{3000}", "g\u{2028}"]) {
            @Assert(!MQGroup.isValid(name))
        }
    }

    @TestCase
    public func chineseGroupNameIsValid(): Unit {
        @Assert(MQGroup.isValid("订单组"))
    }

    @TestCase
    public func overlengthIsRejected(): Unit {
        @Assert(MQGroup.isValid(fill(255)))
        @Assert(!MQGroup.isValid(fill(256)))
    }
}

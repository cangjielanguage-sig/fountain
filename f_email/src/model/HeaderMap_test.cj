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
package fountain::f_email.model

import std.unittest.*
import std.unittest.testmacro.*

@Test
public class HeaderMap_test {
    @TestCase
    public func receivedChainKeepsOrder(): Unit {
        let headers = HeaderMap()
        headers.add("Received", "from a")
        headers.add("Received", "from b")
        headers.add("Received", "from c")
        @Assert(headers.entries().size, 3)
        @Assert(headers.get("received") ?? "", "from a")
        @Assert(headers.getAll("RECEIVED").size, 3)
        @Assert(headers.getAll("received")[2], "from c")
    }

    @TestCase
    public func lookupIsCaseInsensitive(): Unit {
        let headers = HeaderMap()
        headers.add("Subject", "hello")
        @Assert(headers.get("subject") ?? "", "hello")
        @Assert(headers.contains("SUBJECT"), true)
    }

    @TestCase
    public func setReplacesFirstAndDropsRest(): Unit {
        let headers = HeaderMap()
        headers.add("X-A", "1")
        headers.add("X-B", "b")
        headers.add("x-a", "2")
        headers.set("X-A", "new")
        @Assert(headers.getAll("X-A").size, 1)
        @Assert(headers.get("x-a") ?? "", "new")
        @Assert(headers.entries()[0][1], "new")
        @Assert(headers.entries()[1][1], "b")
    }

    @TestCase
    public func removeReturnsOldValuesInOrder(): Unit {
        let headers = HeaderMap()
        headers.add("Comments", "one")
        headers.add("Comments", "two")
        let removed = headers.remove("comments")
        @Assert(removed.size, 2)
        @Assert(removed[0], "one")
        @Assert(removed[1], "two")
        @Assert(headers.contains("Comments"), false)
    }

    @TestCase
    public func rejectsHeaderInjection(): Unit {
        let headers = HeaderMap()
        var caught = false
        try {
            headers.set("Subject", "x\r\nBcc: victim@example.com")
        } catch (_: MailProtocolException) {
            caught = true
        }
        @Assert(caught, true)
        @Assert(headers.size, 0)
    }

    @TestCase
    public func rejectsInvalidFieldName(): Unit {
        var caught = false
        try {
            HeaderMap().add("Bad:Name", "v")
        } catch (_: MailProtocolException) {
            caught = true
        }
        @Assert(caught, true)
    }

    @TestCase
    public func rejectsOverlongValue(): Unit {
        let huge = String(Array<Rune>(999, repeat: r'a'))
        var caught = false
        try {
            HeaderMap().add("X-Long", huge)
        } catch (e: MailLimitException) {
            caught = e.kind.toString() == "Header"
        }
        @Assert(caught, true)
    }

    @TestCase
    public func keepsRawUtf8Value(): Unit {
        let headers = HeaderMap()
        headers.add("Subject", "中文主题")
        @Assert(headers.get("Subject") ?? "", "中文主题")
    }

    @TestCase
    public func namesAreUniqueInOrder(): Unit {
        let headers = HeaderMap()
        headers.add("B", "1")
        headers.add("A", "2")
        headers.add("b", "3")
        let names = headers.names()
        @Assert(names.size, 2)
        @Assert(names[0], "B")
        @Assert(names[1], "A")
    }
}

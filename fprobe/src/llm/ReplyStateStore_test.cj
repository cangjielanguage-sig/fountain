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
package fountain::fprobe.llm

import std.collection.ArrayList
import std.fs.{Path, File}
import std.unittest.*
import std.unittest.testmacro.*

/** 16.6：落盘、重启不重复、文件损坏按空集合、最多 1000 条。 */
@Test
public class ReplyStateStore_test {
    @TestCase
    public func handledIdsSurviveRestart(): Unit {
        let dir = llmTempDir()
        let path = Path(dir).join("reply-state.json").toString()
        let first = ReplyStateStore(path)

        first.markHandled("m1")
        first.markHandled("m2")

        let second = ReplyStateStore(path)
        @Assert(second.isHandled("m1"))
        @Assert(second.isHandled("m2"))
        @Assert(!second.isHandled("m3"))
        @Assert(second.size(), 2)
    }

    @TestCase
    public func corruptFileStartsEmptyAndCanBeWritten(): Unit {
        let dir = llmTempDir()
        let path = Path(dir).join("reply-state.json").toString()
        File.writeTo(path, "not-json".toArray())
        let warnings = ArrayList<String>()
        let store = ReplyStateStore(path, logWarning: {message => warnings.add(message)})

        @Assert(store.size(), 0)
        @Assert(warnings.size, 1)
        store.markHandled("m1")

        let reloaded = ReplyStateStore(path)
        @Assert(reloaded.isHandled("m1"))
    }

    @TestCase
    public func keepsOnlyLatestThousandIds(): Unit {
        let dir = llmTempDir()
        let path = Path(dir).join("reply-state.json").toString()
        let store = ReplyStateStore(path)

        for (i in 0..1005) {
            store.markHandled("m${i}")
        }

        @Assert(store.size(), 1000)
        @Assert(!store.isHandled("m0"))
        @Assert(!store.isHandled("m4"))
        @Assert(store.isHandled("m5"))
        @Assert(store.isHandled("m1004"))

        let reloaded = ReplyStateStore(path)
        @Assert(reloaded.size(), 1000)
        @Assert(!reloaded.isHandled("m0"))
        @Assert(reloaded.isHandled("m1004"))
    }

    @TestCase
    public func missingFileIsEmptyAndCreatesParentDirectory(): Unit {
        let dir = llmTempDir()
        let path = Path(dir).join("nested").join("reply-state.json").toString()
        let store = ReplyStateStore(path)

        @Assert(store.size(), 0)
        store.markHandled("m1")
        let reloaded = ReplyStateStore(path)
        @Assert(reloaded.isHandled("m1"))
    }
}

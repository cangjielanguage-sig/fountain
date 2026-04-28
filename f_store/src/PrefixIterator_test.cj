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
package fountain::f_store

import std.unittest.*
import std.unittest.testmacro.*

@Test
public class PrefixIteratorTest {

    @TestCase
    public func testStartsWith(): Unit {
        let key = ByteArray("hello".unsafeBytes())
        @Expect(startsWith(key, ByteArray("hel".unsafeBytes())))
        @Expect(startsWith(key, ByteArray("hello".unsafeBytes())))
        @Expect(!startsWith(key, ByteArray("world".unsafeBytes())))
        @Expect(!startsWith(key, ByteArray("hello!".unsafeBytes())))
        // 空前缀匹配任意 key
        @Expect(startsWith(key, ByteArray(Array<Byte>())))
    }

    @TestCase
    public func testPrefixIteratorBasic(): Unit {
        let dir = getTestDir("basic")
        let store = Store(dir)
        // 添加同前缀键
        store.add("user:1".unsafeBytes(), "alice".unsafeBytes())
        store.add("user:2".unsafeBytes(), "bob".unsafeBytes())
        store.add("user:3".unsafeBytes(), "carol".unsafeBytes())
        // 添加不同前缀键
        store.add("order:1".unsafeBytes(), "o1".unsafeBytes())

        let iter = store.prefix("user:".unsafeBytes())
        var count = 0
        var found1 = false
        var found2 = false
        var found3 = false
        while (let Some((k, v)) <- iter.next()) {
            let key = String.fromUtf8(k)
            let val = String.fromUtf8(v)
            if (key == "user:1") { found1 = true; @Expect(val == "alice") }
            if (key == "user:2") { found2 = true; @Expect(val == "bob") }
            if (key == "user:3") { found3 = true; @Expect(val == "carol") }
            count++
        }
        @Expect(found1)
        @Expect(found2)
        @Expect(found3)
        @Expect(count == 3)
        store.close()
    }

    @TestCase
    public func testPrefixIteratorEmptyResult(): Unit {
        let dir = getTestDir("empty")
        let store = Store(dir)
        store.add("user:1".unsafeBytes(), "alice".unsafeBytes())
        // 查询不匹配的前缀
        let iter = store.prefix("order:".unsafeBytes())
        @Expect(iter.next().isNone())
        store.close()
    }

    @TestCase
    public func testPrefixIteratorTombstone(): Unit {
        let dir = getTestDir("tombstone")
        let store = Store(dir)
        store.add("user:1".unsafeBytes(), "alice".unsafeBytes())
        store.add("user:2".unsafeBytes(), "bob".unsafeBytes())
        // 删除 user:1
        store.remove("user:1".unsafeBytes())

        let iter = store.prefix("user:".unsafeBytes())
        var count = 0
        var found2 = false
        while (let Some((k, v)) <- iter.next()) {
            let key = String.fromUtf8(k)
            if (key == "user:2") { found2 = true; @Expect(v == "bob".unsafeBytes()) }
            count++
        }
        @Expect(found2)
        @Expect(count == 1)
        store.close()
    }

    @TestCase
    public func testPrefixIteratorAfterClose(): Unit {
        let dir = getTestDir("after_close")
        let store = Store(dir)
        store.close()
        var threw = false
        try {
            store.prefix("x".unsafeBytes())
        } catch (_: StoreClosedException) {
            threw = true
        }
        @Expect(threw)
    }

    func getTestDir(name: String): String {
        let baseDir = "/tmp/f_store_test/PrefixIterator_${name}"
        if (exists(baseDir)) {
            remove(baseDir, recursive: true)
        }
        baseDir
    }
}

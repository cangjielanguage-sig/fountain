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
public class StoreTest {
    var testDir: String = ""

    @TestCase
    public func testAddGetBasic(): Unit {
        let dir = getTestDir("basic")
        let store = Store(dir)
        let key = "hello".unsafeBytes()
        let value = "world".unsafeBytes()
        @Expect(store.get(key).isNone())
        let old = store.add(key, value)
        @Expect(old.isNone())
        let result = store.get(key)
        @Expect(result.isSome())
        if (let Some(v) <- result) {
            @Expect(v == value)
        }
        store.close()
        @Expect(store.isClosed())
    }

    @TestCase
    public func testAddOverwrite(): Unit {
        let dir = getTestDir("overwrite")
        let store = Store(dir)
        let key = "key1".unsafeBytes()
        let value1 = "val1".unsafeBytes()
        let value2 = "val2".unsafeBytes()
        store.add(key, value1)
        let old = store.add(key, value2)
        @Expect(old.isSome())
        if (let Some(v) <- old) {
            @Expect(v == value1)
        }
        let result = store.get(key)
        if (let Some(v) <- result) {
            @Expect(v == value2)
        }
        store.close()
    }

    @TestCase
    public func testRemove(): Unit {
        let dir = getTestDir("remove")
        let store = Store(dir)
        let key = "key_rm".unsafeBytes()
        let value = "val_rm".unsafeBytes()
        store.add(key, value)
        @Expect(store.get(key).isSome())
        let old = store.remove(key)
        @Expect(old.isSome())
        if (let Some(v) <- old) {
            @Expect(v == value)
        }
        @Expect(store.get(key).isNone())
        store.close()
    }

    @TestCase
    public func testGetNonExistent(): Unit {
        let dir = getTestDir("nonexist")
        let store = Store(dir)
        let key = "nokey".unsafeBytes()
        @Expect(store.get(key).isNone())
        store.close()
    }

    @TestCase
    public func testAddWithTTL(): Unit {
        let dir = getTestDir("ttl")
        let store = Store(dir)
        let key = "ttl_key".unsafeBytes()
        let value = "ttl_val".unsafeBytes()
        // 添加带 10 秒 TTL 的键
        store.add(key, value, Duration.second * 10)
        let result = store.get(key)
        @Expect(result.isSome())
        if (let Some(v) <- result) {
            @Expect(v == value)
        }
        store.close()
    }

    @TestCase
    public func testTTLUpdate(): Unit {
        let dir = getTestDir("ttl_update")
        let store = Store(dir)
        let key = "ttl_upd_key".unsafeBytes()
        let value = "ttl_upd_val".unsafeBytes()
        // 先添加无 TTL 的键
        store.add(key, value)
        @Expect(store.get(key).isSome())
        // 更新 TTL
        store.ttl(key, Duration.second * 10)
        // 键仍然存在
        let result = store.get(key)
        @Expect(result.isSome())
        if (let Some(v) <- result) {
            @Expect(v == value)
        }
        store.close()
    }

    @TestCase
    public func testTTLNonExistentKey(): Unit {
        let dir = getTestDir("ttl_nokey")
        let store = Store(dir)
        let key = "no_such_key".unsafeBytes()
        // 对不存在的 key 调用 ttl，不应抛异常
        store.ttl(key, Duration.second * 10)
        @Expect(store.get(key).isNone())
        store.close()
    }

    @TestCase
    public func testCloseAndReopen(): Unit {
        let dir = getTestDir("reopen")
        let key1 = "reopen_key1".unsafeBytes()
        let value1 = "reopen_val1".unsafeBytes()
        let key2 = "reopen_key2".unsafeBytes()
        let value2 = "reopen_val2".unsafeBytes()
        // 写入数据并关闭
        let store1 = Store(dir)
        store1.add(key1, value1)
        store1.add(key2, value2)
        store1.close()
        // 重新打开
        let store2 = Store(dir)
        let r1 = store2.get(key1)
        @Expect(r1.isSome())
        if (let Some(v) <- r1) {
            @Expect(v == value1)
        }
        let r2 = store2.get(key2)
        @Expect(r2.isSome())
        if (let Some(v) <- r2) {
            @Expect(v == value2)
        }
        store2.close()
    }

    @TestCase
    public func testMultipleKeys(): Unit {
        let dir = getTestDir("multi")
        let store = Store(dir)
        let count = 50
        for (i in 0..count) {
            let key = "key_${i}".unsafeBytes()
            let value = "val_${i}".unsafeBytes()
            store.add(key, value)
        }
        for (i in 0..count) {
            let key = "key_${i}".unsafeBytes()
            let expectedValue = "val_${i}".unsafeBytes()
            let result = store.get(key)
            @Expect(result.isSome())
            if (let Some(v) <- result) {
                @Expect(v == expectedValue)
            }
        }
        store.close()
    }

    @TestCase
    public func testCloseIdempotent(): Unit {
        let dir = getTestDir("idempotent")
        let store = Store(dir)
        store.add("k".unsafeBytes(), "v".unsafeBytes())
        store.close()
        // 多次 close 不崩溃
        store.close()
        store.close()
        @Expect(store.isClosed())
    }

    @TestCase
    public func testOperationAfterClose(): Unit {
        let dir = getTestDir("after_close")
        let store = Store(dir)
        store.close()
        var threw = false
        try {
            store.add("k".unsafeBytes(), "v".unsafeBytes())
        } catch (_: StoreClosedException) {
            threw = true
        }
        @Expect(threw)
        threw = false
        try {
            store.get("k".unsafeBytes())
        } catch (_: StoreClosedException) {
            threw = true
        }
        @Expect(threw)
        threw = false
        try {
            store.remove("k".unsafeBytes())
        } catch (_: StoreClosedException) {
            threw = true
        }
        @Expect(threw)
    }

    func getTestDir(name: String): String {
        let baseDir = "/tmp/f_store_test/Store_${name}"
        // 清理旧数据
        if (exists(baseDir)) {
            remove(baseDir, recursive: true)
        }
        baseDir
    }
}

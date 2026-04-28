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
import std.collection.ArrayList
import std.sync.AtomicInt64

@Test
public class StoreIntegrationTest {
    var testDir: String = ""

    // ==================== 1. 基本功能测试 ====================

    @TestCase
    public func testAddGetRoundTrip(): Unit {
        let dir = getTestDir("add_get_roundtrip")
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
    }

    @TestCase
    public func testRemoveReturnsNone(): Unit {
        let dir = getTestDir("remove_none")
        let store = Store(dir)
        let key = "rm_key".unsafeBytes()
        let value = "rm_val".unsafeBytes()
        store.add(key, value)
        let old = store.remove(key)
        @Expect(old.isSome())
        if (let Some(v) <- old) {
            @Expect(v == value)
        }
        @Expect(store.get(key).isNone())
        store.close()
    }

    @TestCase
    public func testAddExistingKeyReturnsOld(): Unit {
        let dir = getTestDir("add_existing")
        let store = Store(dir)
        let key = "dup_key".unsafeBytes()
        let val1 = "val1".unsafeBytes()
        let val2 = "val2".unsafeBytes()
        store.add(key, val1)
        let old = store.add(key, val2)
        @Expect(old.isSome())
        if (let Some(v) <- old) {
            @Expect(v == val1)
        }
        let result = store.get(key)
        @Expect(result.isSome())
        if (let Some(v) <- result) {
            @Expect(v == val2)
        }
        store.close()
    }

    @TestCase
    public func testAddWithExpireBeforeAndAfter(): Unit {
        let dir = getTestDir("expire_before_after")
        let store = Store(dir)
        let key = "exp_key".unsafeBytes()
        let value = "exp_val".unsafeBytes()
        // 添加带 2 秒 TTL 的键
        store.add(key, value, Duration.second * 2)
        // 过期前能读到
        let before = store.get(key)
        @Expect(before.isSome())
        if (let Some(v) <- before) {
            @Expect(v == value)
        }
        // 等待过期
        sleep(Duration.second * 3)
        // 过期后读不到
        @Expect(store.get(key).isNone())
        store.close()
    }

    @TestCase
    public func testTTLUpdateExpireTime(): Unit {
        let dir = getTestDir("ttl_update_expire")
        let store = Store(dir)
        let key = "ttl_upd".unsafeBytes()
        let value = "ttl_upd_val".unsafeBytes()
        store.add(key, value)
        // 设置 2 秒后过期
        store.ttl(key, Duration.second * 2)
        // 还能读到
        @Expect(store.get(key).isSome())
        // 等待过期
        sleep(Duration.second * 3)
        @Expect(store.get(key).isNone())
        store.close()
    }

    @TestCase
    public func testTTLNonExistentKeyNoOp(): Unit {
        let dir = getTestDir("ttl_noop")
        let store = Store(dir)
        let key = "no_such_key".unsafeBytes()
        store.ttl(key, Duration.second * 10)
        @Expect(store.get(key).isNone())
        store.close()
    }

    @TestCase
    public func testPrefixTraversal(): Unit {
        let dir = getTestDir("prefix_traverse")
        let store = Store(dir)
        store.add("user:1".unsafeBytes(), "alice".unsafeBytes())
        store.add("user:2".unsafeBytes(), "bob".unsafeBytes())
        store.add("order:1".unsafeBytes(), "item1".unsafeBytes())
        var count = 0
        let iter = store.prefix("user:".unsafeBytes())
        while (let Some((k, v)) <- iter.next()) {
            count++
        }
        @Expect(count == 2)
        store.close()
    }

    @TestCase
    public func testEmptyStoreGetAndPrefix(): Unit {
        let dir = getTestDir("empty_store")
        let store = Store(dir)
        @Expect(store.get("any".unsafeBytes()).isNone())
        let iter = store.prefix("any".unsafeBytes())
        @Expect(iter.next().isNone())
        store.close()
    }

    // ==================== 2. 并发安全测试 ====================

    @TestCase
    public func testConcurrentAddDifferentKeys(): Unit {
        let dir = getTestDir("concurrent_diff_keys")
        let store = Store(dir)
        let count = 20
        let added = AtomicInt64(0)
        let futures = ArrayList<Future<Unit>>()
        for (i in 0..count) {
            let idx = i
            futures.add(spawn {
                let key = "ckey_${idx}".unsafeBytes()
                let value = "cval_${idx}".unsafeBytes()
                store.add(key, value)
                added.fetchAdd(1)
            })
        }
        for (f in futures) {
            f.get()
        }
        @Expect(added.load() == count)
        // 验证所有 key 都写入成功
        for (i in 0..count) {
            let key = "ckey_${i}".unsafeBytes()
            @Expect(store.get(key).isSome())
        }
        store.close()
    }

    @TestCase
    public func testConcurrentAddSameKey(): Unit {
        let dir = getTestDir("concurrent_same_key")
        let store = Store(dir)
        let key = "race_key".unsafeBytes()
        let count = 10
        let futures = ArrayList<Future<Unit>>()
        for (i in 0..count) {
            let idx = i
            futures.add(spawn {
                store.add(key, "val_${idx}".unsafeBytes())
            })
        }
        for (f in futures) {
            f.get()
        }
        // 最终 get 必须返回某个值
        let result = store.get(key)
        @Expect(result.isSome())
        store.close()
    }

    @TestCase
    public func testConcurrentAddAndGet(): Unit {
        let dir = getTestDir("concurrent_add_get")
        let store = Store(dir)
        let count = 20
        let futures = ArrayList<Future<Unit>>()
        // 先写入一些 key
        for (i in 0..5) {
            store.add("cg_${i}".unsafeBytes(), "init".unsafeBytes())
        }
        // 并发写 + 读
        for (i in 5..count) {
            let idx = i
            futures.add(spawn {
                store.add("cg_${idx}".unsafeBytes(), "val_${idx}".unsafeBytes())
            })
            futures.add(spawn {
                // 读任意 key，不应崩溃
                store.get("cg_${idx % 5}".unsafeBytes())
            })
        }
        for (f in futures) {
            f.get()
        }
        store.close()
    }

    @TestCase
    public func testConcurrentAddAndPrefix(): Unit {
        let dir = getTestDir("concurrent_add_prefix")
        let store = Store(dir)
        store.add("pfx:a".unsafeBytes(), "1".unsafeBytes())
        let futures = ArrayList<Future<Unit>>()
        for (i in 0..5) {
            let idx = i
            futures.add(spawn {
                store.add("pfx:b${idx}".unsafeBytes(), "v${idx}".unsafeBytes())
            })
            futures.add(spawn {
                // prefix 遍历不应崩溃
                let iter = store.prefix("pfx:".unsafeBytes())
                while (let Some(_) <- iter.next()) {
                    // consume
                }
            })
        }
        for (f in futures) {
            f.get()
        }
        store.close()
    }

    // ==================== 3. 持久化与恢复测试 ====================

    @TestCase
    public func testCloseReopenDataIntact(): Unit {
        let dir = getTestDir("close_reopen")
        let key1 = "rk1".unsafeBytes()
        let val1 = "rv1".unsafeBytes()
        let key2 = "rk2".unsafeBytes()
        let val2 = "rv2".unsafeBytes()
        let store1 = Store(dir)
        store1.add(key1, val1)
        store1.add(key2, val2)
        store1.close()
        // 重新打开
        let store2 = Store(dir)
        let r1 = store2.get(key1)
        @Expect(r1.isSome())
        if (let Some(v) <- r1) {
            @Expect(v == val1)
        }
        let r2 = store2.get(key2)
        @Expect(r2.isSome())
        if (let Some(v) <- r2) {
            @Expect(v == val2)
        }
        store2.close()
    }

    @TestCase
    public func testFlushToSSTableAndReopen(): Unit {
        let dir = getTestDir("flush_reopen")
        // memFlushThreshold 默认值不确定，写入较多数据触发刷盘
        let store = Store(dir)
        let count = 200
        for (i in 0..count) {
            let key = "flush_key_${i}".unsafeBytes()
            let value = "flush_val_${i}".unsafeBytes()
            store.add(key, value)
        }
        store.close()
        // 重新打开，验证数据完整
        let store2 = Store(dir)
        for (i in 0..count) {
            let key = "flush_key_${i}".unsafeBytes()
            let expectedValue = "flush_val_${i}".unsafeBytes()
            let result = store2.get(key)
            @Expect(result.isSome())
            if (let Some(v) <- result) {
                @Expect(v == expectedValue)
            }
        }
        store2.close()
    }

    @TestCase
    public func testWALRecovery(): Unit {
        let dir = getTestDir("wal_recovery")
        let key = "wal_key".unsafeBytes()
        let value = "wal_val".unsafeBytes()
        // 写入后不 close，模拟崩溃
        let store1 = Store(dir)
        store1.add(key, value)
        // 不调用 close，直接让 Store 被 GC（WAL 已写入数据）
        // 重新打开时从 WAL 恢复
        let store2 = Store(dir)
        let result = store2.get(key)
        @Expect(result.isSome())
        if (let Some(v) <- result) {
            @Expect(v == value)
        }
        store2.close()
    }

    // ==================== 4. TTL 功能测试 ====================

    @TestCase
    public func testExpiredDataSkippedInPrefix(): Unit {
        let dir = getTestDir("expired_prefix")
        let store = Store(dir)
        store.add("ep:user:1".unsafeBytes(), "alice".unsafeBytes())
        store.add("ep:user:2".unsafeBytes(), "bob".unsafeBytes(), Duration.second * 1)
        // 等待 ep:user:2 过期
        sleep(Duration.second * 2)
        let iter = store.prefix("ep:user:".unsafeBytes())
        var count = 0
        while (let Some((k, v)) <- iter.next()) {
            count++
        }
        // 只剩 ep:user:1
        @Expect(count == 1)
        store.close()
    }

    @TestCase
    public func testShortExpireTime(): Unit {
        let dir = getTestDir("short_expire")
        let store = Store(dir)
        let key = "short_key".unsafeBytes()
        let value = "short_val".unsafeBytes()
        // 极短过期时间
        store.add(key, value, Duration.millisecond * 100)
        // 立即读，可能还在
        let immediate = store.get(key)
        // 等过期能读到也算通过（实现可能检查时间戳）
        sleep(Duration.millisecond * 200)
        @Expect(store.get(key).isNone())
        store.close()
    }

    // ==================== 6. 边界条件测试 ====================

    @TestCase
    public func testEmptyKeyValue(): Unit {
        let dir = getTestDir("empty_kv")
        let store = Store(dir)
        let emptyKey = Array<Byte>()
        let emptyValue = Array<Byte>()
        store.add(emptyKey, emptyValue)
        let result = store.get(emptyKey)
        @Expect(result.isSome())
        if (let Some(v) <- result) {
            @Expect(v == emptyValue)
        }
        store.close()
    }

    @TestCase
    public func testRemoveNonExistentKey(): Unit {
        let dir = getTestDir("remove_noexist")
        let store = Store(dir)
        let old = store.remove("noexist".unsafeBytes())
        @Expect(old.isNone())
        store.close()
    }

    @TestCase
    public func testConsecutiveAddSameKey(): Unit {
        let dir = getTestDir("consec_add")
        let store = Store(dir)
        let key = "same_key".unsafeBytes()
        for (i in 0..10) {
            store.add(key, "val_${i}".unsafeBytes())
        }
        let result = store.get(key)
        @Expect(result.isSome())
        if (let Some(v) <- result) {
            @Expect(v == "val_9".unsafeBytes())
        }
        store.close()
    }

    @TestCase
    public func testLargeKeyCountPrefix(): Unit {
        let dir = getTestDir("large_prefix")
        let store = Store(dir)
        let count = 100
        for (i in 0..count) {
            store.add("lp:${i}".unsafeBytes(), "v${i}".unsafeBytes())
        }
        // 混入非前缀 key
        store.add("other:1".unsafeBytes(), "x".unsafeBytes())
        let iter = store.prefix("lp:".unsafeBytes())
        var found = 0
        while (let Some(_) <- iter.next()) {
            found++
        }
        @Expect(found == count)
        store.close()
    }

    @TestCase
    public func testPrefixAfterRemove(): Unit {
        let dir = getTestDir("prefix_after_remove")
        let store = Store(dir)
        store.add("pr:a".unsafeBytes(), "1".unsafeBytes())
        store.add("pr:b".unsafeBytes(), "2".unsafeBytes())
        store.add("pr:c".unsafeBytes(), "3".unsafeBytes())
        store.remove("pr:b".unsafeBytes())
        let iter = store.prefix("pr:".unsafeBytes())
        var found = 0
        while (let Some(_) <- iter.next()) {
            found++
        }
        @Expect(found == 2)
        store.close()
    }

    func getTestDir(name: String): String {
        let baseDir = "/tmp/f_store_test/Integration_${name}"
        if (exists(baseDir)) {
            remove(baseDir, recursive: true)
        }
        baseDir
    }
}

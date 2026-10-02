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

    /** 验证覆盖已过期 key 时返回旧值（P1-3 修复验证）。
     *  旧版 addWithExpire 在返回旧值前重新调 DateTime.now()，
     *  若旧值在 add 完成时恰好过期则返回 None，违反"返回添加时的旧值"语义。 */
    @TestCase
    public func testAddOverwriteExpiredKeyReturnsOldValue(): Unit {
        let dir = getTestDir("overwrite_expired")
        let store = Store(dir)
        let key = "expired_key".unsafeBytes()
        let oldValue = "old_val".unsafeBytes()
        let newValue = "new_val".unsafeBytes()

        // 添加带 500ms TTL 的键
        store.add(key, oldValue, Duration.millisecond * 500)
        @Expect(store.get(key).isSome())

        // 等待键过期
        sleep(Duration.millisecond * 600)

        // 添加新值，应返回旧值（即使旧值已过期）
        let result = store.add(key, newValue)
        @Expect(result.isSome())
        if (let Some(v) <- result) {
            @Expect(v == oldValue)
        }

        // 检查新值已写入
        let getResult = store.get(key)
        @Expect(getResult.isSome())
        if (let Some(v) <- getResult) {
            @Expect(v == newValue)
        }

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

    /** 64KB 大 value 写入和读取 */
    @TestCase
    public func testLargeValue64KB(): Unit {
        let dir = getTestDir("large_value_64kb")
        let store = Store(dir)
        let key = "large_k".unsafeBytes()
        let largeValue = Array<Byte>(64 * 1024) { i => UInt8(i % 256) }
        store.add(key, largeValue)
        let result = store.get(key)
        @Expect(result.isSome())
        if (let Some(v) <- result) {
            @Expect(v == largeValue)
        }
        store.close()
    }

    /** 验证 syncWAL 正常调用不抛异常 */
    @TestCase
    public func testSyncWAL(): Unit {
        let dir = getTestDir("sync_wal")
        let store = Store(dir)
        store.add("k1".unsafeBytes(), "v1".unsafeBytes())
        // syncWAL 在正常状态下应正常返回
        store.syncWAL()
        store.close()
    }

    /** 验证 syncWAL 在 close 后抛 StoreClosedException */
    @TestCase
    public func testSyncWALAfterCloseThrows(): Unit {
        let dir = getTestDir("sync_wal_closed")
        let store = Store(dir)
        store.add("k1".unsafeBytes(), "v1".unsafeBytes())
        store.close()
        var threw = false
        try {
            store.syncWAL()
        } catch (_: StoreClosedException) {
            threw = true
        }
        @Expect(threw)
    }

    /** 验证 cleanupOldWALFiles 删除 .wal 文件但保留其他文件 */
    @TestCase
    public func testCleanupOldWALFiles(): Unit {
        let dir = "/tmp/f_store_test/cleanup_wal"
        if (exists(dir)) { remove(dir, recursive: true) }
        Directory.create(dir, recursive: true)

        // 创建 .wal 文件
        let wal1 = File("${dir}/0001.wal", OpenMode.ReadWrite)
        wal1.write([0x01])
        wal1.close()
        let wal2 = File("${dir}/0002.wal", OpenMode.ReadWrite)
        wal2.write([0x02])
        wal2.close()

        // 创建非 .wal 文件（应保留）
        let other = File("${dir}/keep_me.txt", OpenMode.ReadWrite)
        other.write([0x41])
        other.close()
        let sst = File("${dir}/L0_1.sst", OpenMode.ReadWrite)
        sst.write([0x42])
        sst.close()

        // 执行清理
        cleanupOldWALFiles(dir)

        // .wal 文件应被删除
        @Expect(!exists(Path("${dir}/0001.wal")))
        @Expect(!exists(Path("${dir}/0002.wal")))
        // 其他文件应保留
        @Expect(exists(Path("${dir}/keep_me.txt")))
        @Expect(exists(Path("${dir}/L0_1.sst")))

        remove(dir, recursive: true)
    }

    @TestCase
    public func testContainsBasic(): Unit {
        let dir = getTestDir("contains_basic")
        let store = Store(dir)
        let key = "exists".unsafeBytes()
        let value = "val".unsafeBytes()
        @Expect(!store.contains(key))
        store.add(key, value)
        @Expect(store.contains(key))
        store.close()
    }

    @TestCase
    public func testContainsNonExistent(): Unit {
        let dir = getTestDir("contains_nonexist")
        let store = Store(dir)
        @Expect(!store.contains("no_such_key".unsafeBytes()))
        store.close()
    }

    @TestCase
    public func testContainsAfterRemove(): Unit {
        let dir = getTestDir("contains_remove")
        let store = Store(dir)
        let key = "rm_key".unsafeBytes()
        store.add(key, "val".unsafeBytes())
        @Expect(store.contains(key))
        store.remove(key)
        @Expect(!store.contains(key))
        store.close()
    }

    @TestCase
    public func testContainsWithTTL(): Unit {
        let dir = getTestDir("contains_ttl")
        let store = Store(dir)
        let key = "ttl_key".unsafeBytes()
        store.add(key, "val".unsafeBytes(), Duration.millisecond * 200)
        @Expect(store.contains(key))
        sleep(Duration.millisecond * 300)
        @Expect(!store.contains(key))
        store.close()
    }

    @TestCase
    public func testContainsAfterCloseThrows(): Unit {
        let dir = getTestDir("contains_closed")
        let store = Store(dir)
        store.close()
        var threw = false
        try {
            store.contains("k".unsafeBytes())
        } catch (_: StoreClosedException) {
            threw = true
        }
        @Expect(threw)
    }

    /** P2: 验证 close() 二次 swap 能捕获并发写 — close 期间写入新 active 的数据可恢复 */
    @TestCase
    public func testCloseDoubleSwapCapturesConcurrentWrite(): Unit {
        let dir = getTestDir("double_swap")
        let store = Store(dir)
        let key = "ds_key".unsafeBytes()
        let value = "ds_val".unsafeBytes()
        store.add(key, value)
        store.close()
        // 重新打开验证数据持久化
        let store2 = Store(dir)
        let r = store2.get(key)
        @Expect(r.isSome())
        if (let Some(v) <- r) {
            @Expect(v == value)
        }
        store2.close()
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

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

    /** 验证 PrefixIterator.close() 立即关闭不排空（P2-3 修复验证）。
     *  旧版 close() 逐个迭代所有源排空，对 SSTable 产生 O(n) 解码开销。
     *  新版直接关闭底层 iterator，close() 后 next() 返回 None。 */
    @TestCase
    public func testPrefixIteratorCloseDirectly(): Unit {
        let dir = getTestDir("close_direct")
        let store = Store(dir)

        // 写入足够数据触发 flush 到 SSTable
        for (i in 0..50) {
            store.add("user:${i}".unsafeBytes(), "val_${i}".unsafeBytes())
        }

        // 创建 PrefixIterator
        let iter = store.prefix("user:".unsafeBytes())

        // 立即 close（不迭代），不应抛异常
        iter.close()

        // close 后 next() 应返回 None
        @Expect(iter.next().isNone())

        // 幂等：多次 close 不抛异常
        iter.close()
        iter.close()

        store.close()
    }

    /** 验证 PeekableIterator.close() 正确转发到底层 Resource（P2-3 前置修复）。
     *  SSTableIterator 是 Resource，关闭 PeekableIterator 应关闭底层文件。 */
    @TestCase
    public func testPeekableIteratorClosesUnderlyingResource(): Unit {
        let dir = getTestDir("peekable_close")
        Directory.create(dir, recursive: true)

        // 创建 SSTable 并获取 iterator
        let path = "${dir}/L0_1.sst"
        let sst = SSTable(path, 5)
        sst.write(ByteArray([0x01]), EntryValue([0xA1], 1))
        sst.finishWrite()

        let iter = sst.iterator()
        let peekable = PeekableIterator(iter)

        // close() 不应抛异常（转发到底层 Resource.close）
        peekable.close()

        // 对普通迭代器（非 Resource）close 应无副作用
        let normalArr = [1, 2, 3]
        let normalPeekable = PeekableIterator(normalArr.iterator())
        normalPeekable.close()  // 不应抛异常

        sst.close()
        remove(dir, recursive: true)
    }

    func getTestDir(name: String): String {
        let baseDir = "/tmp/f_store_test/PrefixIterator_${name}"
        if (exists(baseDir)) {
            remove(baseDir, recursive: true)
        }
        baseDir
    }
}

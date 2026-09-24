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
import std.fs.*
import std.collection.ArrayList

@Test
public class MemTableTest {

    @TestCase
    public func memTableAddAndGet(): Unit {
        let mt = MemTable()
        mt.add(ByteArray([0x01]), EntryValue([0x0A], 1))
        mt.add(ByteArray([0x02]), EntryValue([0x0B], 2))
        let v1 = mt.get(ByteArray([0x01]))
        let v2 = mt.get(ByteArray([0x02]))
        let v3 = mt.get(ByteArray([0x03]))
        @Expect(v1.isSome())
        @Expect(v2.isSome())
        @Expect(v3.isNone())
        if (let Some(e) <- v1) {
            @Expect(e.sequence == 1)
        }
        if (let Some(e) <- v2) {
            @Expect(e.sequence == 2)
        }
    }

    @TestCase
    public func memTableAddOverwrite(): Unit {
        let mt = MemTable()
        mt.add(ByteArray([0x01]), EntryValue([0x0A], 1))
        let old = mt.add(ByteArray([0x01]), EntryValue([0x0B], 2))
        // 旧值应返回
        if (let Some(e) <- old) {
            @Expect(e.sequence == 1)
        } else {
            @Assert(false)
        }
        // get 返回新值
        let cur = mt.get(ByteArray([0x01]))
        if (let Some(e) <- cur) {
            @Expect(e.sequence == 2)
        } else {
            @Assert(false)
        }
    }

    @TestCase
    public func memTableTombstone(): Unit {
        let mt = MemTable()
        mt.add(ByteArray([0x01]), EntryValue([0x0A], 1))
        mt.add(ByteArray([0x01]), EntryValue(None, 2))
        let v = mt.get(ByteArray([0x01]))
        @Expect(v.isSome())
        if (let Some(e) <- v) {
            @Expect(e.value.isNone())
        }
    }

    @TestCase
    public func memTableIterator(): Unit {
        let mt = MemTable()
        mt.add(ByteArray([0x03]), EntryValue([0x0C], 3))
        mt.add(ByteArray([0x01]), EntryValue([0x0A], 1))
        mt.add(ByteArray([0x02]), EntryValue([0x0B], 2))
        let iter = mt.iterator()
        let keys = ArrayList<ByteArray>()
        while (let Some((k, _)) <- iter.next()) {
            keys.add(k)
        }
        // 应有序
        @Expect(keys.size == 3)
        @Expect(keys[0] == ByteArray([0x01]))
        @Expect(keys[1] == ByteArray([0x02]))
        @Expect(keys[2] == ByteArray([0x03]))
    }

    @TestCase
    public func memTableSize(): Unit {
        let mt = MemTable()
        @Expect(mt.approximateSize() == 0)
        mt.add(ByteArray([0x01]), EntryValue([0x0A], 1))
        @Expect(mt.approximateSize() > 0)
    }

    /** 验证覆盖写不会导致 byteCount 持续漂移 */
    @TestCase
    public func memTableByteCountOnOverwrite(): Unit {
        let mt = MemTable()
        // 1KB key + 2KB value
        let key1KB = Array<Byte>(1024){i => 0u8}
        let val2KB = Array<Byte>(2048){i => 1u8}
        let val3KB = Array<Byte>(3072){i => 2u8}
        mt.add(ByteArray(key1KB), EntryValue(val2KB, 1))
        let size1 = mt.approximateSize()
        // 覆盖写，旧 value 2KB 被替换为新 value 3KB，增量应为 1KB
        mt.add(ByteArray(key1KB), EntryValue(val3KB, 2))
        let size2 = mt.approximateSize()
        @Expect(size2 == size1 + 1024) // 仅 net 增量（-2048 + 3072 = +1024）
        // 再次覆盖写，替换为更小的 value
        let val1KB = Array<Byte>(1024){i => 3u8}
        mt.add(ByteArray(key1KB), EntryValue(val1KB, 3))
        let size3 = mt.approximateSize()
        @Expect(size3 == size2 - 2048) // -3072 + 1024 = -2048
    }

    /** P4: 验证 byteCount 正确包含 ENTRY_OVERHEAD (sequence + value ref + expireAt = 24) */
    @TestCase
    public func memTableEntryOverhead(): Unit {
        let mt = MemTable()
        // 添加 1 条记录：key=1B + value=1B + overhead=24 = 26
        mt.add(ByteArray([0x01]), EntryValue([0x0A], 1))
        @Expect(mt.approximateSize() == 26)  // 1 + 1 + 24
        // 添加第二条记录（不同 key）：26 + 26 = 52
        mt.add(ByteArray([0x02]), EntryValue([0x0B], 2))
        @Expect(mt.approximateSize() == 52)
        // 覆盖写第二条（value 从 1B 变为 3B）：52 - 26 + (1 + 3 + 24) = 52 - 26 + 28 = 54
        mt.add(ByteArray([0x02]), EntryValue([0xBB, 0xBB, 0xBB], 3))
        @Expect(mt.approximateSize() == 54)
    }

    /** 验证 tailer 从指定 key 开始遍历 */
    @TestCase
    public func memTableTailer(): Unit {
        let mt = MemTable()
        mt.add(ByteArray([0x01]), EntryValue([0x0A], 1))
        mt.add(ByteArray([0x03]), EntryValue([0x0C], 3))
        mt.add(ByteArray([0x05]), EntryValue([0x0E], 5))

        // 从 key 0x02 开始（跳过 0x01）
        let iter1 = mt.tailer(ByteArray([0x02]))
        let keys1 = ArrayList<ByteArray>()
        while (let Some((k, _)) <- iter1.next()) {
            keys1.add(k)
        }
        @Expect(keys1.size == 2)
        @Expect(keys1[0] == ByteArray([0x03]))
        @Expect(keys1[1] == ByteArray([0x05]))

        // 从已有 key 0x03 开始（包含该 key）
        let iter2 = mt.tailer(ByteArray([0x03]))
        let keys2 = ArrayList<ByteArray>()
        while (let Some((k, _)) <- iter2.next()) {
            keys2.add(k)
        }
        @Expect(keys2.size == 2)

        // 从超出最大 key 的位置开始（空结果）
        let iter3 = mt.tailer(ByteArray([0xFF]))
        @Expect(iter3.next().isNone())

        // 空 MemTable 的 tailer
        let emptyMt = MemTable()
        let iter4 = emptyMt.tailer(ByteArray([0x01]))
        @Expect(iter4.next().isNone())
    }
}
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
public class MemTableManagerTest {

    @TestCase
    public func memTableManagerSwap(): Unit {
        let mgr = MemTableManager()
        // 初始状态：active 非空，immutable 为 None
        @Expect(mgr.getActive().approximateSize() == 0)
        @Expect(mgr.getImmutable().isNone())

        // 写入数据
        mgr.getActive().add(ByteArray([0x01]), EntryValue([0x0A], 1))

        // swap
        let swapped = mgr.swapActive()
        @Expect(swapped.isSome())
        // swap 后 active 是新的空 MemTable
        @Expect(mgr.getActive().approximateSize() == 0)
        // immutable 是旧的
        @Expect(mgr.getImmutable().isSome())
    }

    @TestCase
    public func memTableManagerClearImmutable(): Unit {
        let mgr = MemTableManager()
        mgr.getActive().add(ByteArray([0x01]), EntryValue([0x0A], 1))
        mgr.swapActive()
        @Expect(mgr.getImmutable().isSome())
        mgr.clearImmutable()
        @Expect(mgr.getImmutable().isNone())
    }

    @TestCase
    public func memTableManagerSwapWhileImmutableBusy(): Unit {
        let mgr = MemTableManager()
        mgr.getActive().add(ByteArray([0x01]), EntryValue([0x0A], 1))
        mgr.swapActive()
        // immutable 非空时再次 swap 应返回 None
        let second = mgr.swapActive()
        @Expect(second.isNone())
    }

    /** P3: 验证 clearImmutable() 在 immutable 已为 None 时不抛异常（前置检查） */
    @TestCase
    public func memTableManagerClearImmutableWhenAlreadyNone(): Unit {
        let mgr = MemTableManager()
        @Expect(mgr.getImmutable().isNone())
        // clearImmutable 在 immutable 已为 None 时直接 break，不分配不 CAS
        mgr.clearImmutable()
        @Expect(mgr.getImmutable().isNone())
        // 再次调用不抛异常（幂等）
        mgr.clearImmutable()
        @Expect(mgr.getActive().approximateSize() == 0)
    }

    /** P3: 验证 clearImmutable 后 slot 释放，后续 swap 可正常执行 */
    @TestCase
    public func memTableManagerClearImmutableReleasesSlot(): Unit {
        let mgr = MemTableManager()
        mgr.getActive().add(ByteArray([0x01]), EntryValue([0x0A], 1))
        mgr.swapActive()
        @Expect(mgr.getImmutable().isSome())
        mgr.clearImmutable()
        @Expect(mgr.getImmutable().isNone())
        // slot 释放后，再 swap 应成功
        let swapped = mgr.swapActive()
        @Expect(swapped.isSome())
        if (let Some(t) <- swapped) {
            @Expect(t.approximateSize() == 0)  // 新的 active 为空
        }
    }

    /** 持续 add 直到 byteCount 超限，验证 swap 后可继续写入 */
    @TestCase
    public func memTableManagerCapacityBoundary(): Unit {
        let mgr = MemTableManager()
        // 使用 8KB value 快速撑满 byteCount
        let largeValue = Array<Byte>(8 * 1024, repeat: 66u8)
        var addCount: Int64 = 0
        // 持续写入直到 approximateSize 超过 1MB
        while (mgr.getActive().approximateSize() < 1024 * 1024) {
            let key = "cb_${addCount}".unsafeBytes()
            mgr.getActive().add(ByteArray(key), EntryValue(largeValue, addCount))
            addCount++
        }
        @Expect(addCount > 0)
        // swap 后旧 active 成为 immutable
        let swapped = mgr.swapActive()
        @Expect(swapped.isSome())
        @Expect(mgr.getImmutable().isSome())
        // 新 active 可继续写入
        let newKey = "cb_new".unsafeBytes()
        mgr.getActive().add(ByteArray(newKey), EntryValue([0x01], 999))
        @Expect(mgr.getActive().get(ByteArray(newKey)).isSome())
        // 验证 swapped 中的数据完整
        if (let Some(table) <- swapped) {
            for (i in 0..addCount) {
                let key = "cb_${i}".unsafeBytes()
                let v = table.get(ByteArray(key))
                @Expect(v.isSome())
            }
        }
    }
}
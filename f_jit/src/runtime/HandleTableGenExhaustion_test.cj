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
package fountain::f_jit.runtime

import std.unittest.*
import std.unittest.testmacro.*

/**
 * 句柄世代号耗尽的回归用例（`fix-handle-gen-exhaustion`）。
 *
 * 旧实现把 16 位 gen 放在 Int64 最高位：第 32768 次复用同一槽时 gen = 0x8000 ⇒ ID 为负 ⇒
 * 全库 `id <= 0` 判空把它当空句柄，后续 helper 以 99 失败。本用例的第 32768 轮就是那条边界。
 *
 * 每轮 `openWindow` / `resetWindow` 是为了清空窗口内的 `pin` 去重清单：
 * 否则 3.2 万次 pin 会让去重扫描退化成 O(n²)。
 */
@Test
public class HandleTableGenExhaustion_test {
    /** 同一槽连续复用 32768 次：每一次返回的标识都必须为正且可读。 */
    @TestCase
    public func genExhaustionKeepsIdsPositiveAndReadable(): Unit {
        HandleTable.resetForTest()
        let base = HandleTable.slotCount()
        var round = 0
        var badRound: Int64 = -1
        var badId: Int64 = 0
        var unreadableRound: Int64 = -1
        var lastId: Int64 = 0
        while (round < 32768) {
            HandleTable.openWindow(4)
            let id = HandleTable.pin('gen-probe')
            if (id > 0) {
                lastId = id
                if (!HandleTable.isLiveHandle(id) || HandleTable.getAny(id).isNone()) {
                    if (unreadableRound < 0) {
                        unreadableRound = round
                    }
                }
                HandleTable.release(id)
            } else if (badRound < 0) {
                badRound = round
                badId = id
            }
            HandleTable.resetWindow(-1)
            round = round + 1
        }
        println('GEN-PROBE rounds=' + round.toString() + ' badRound=' + badRound.toString() +
            ' badId=' + badId.toString() + ' unreadableRound=' + unreadableRound.toString() +
            ' slotCount=' + HandleTable.slotCount().toString() + ' base=' + base.toString() +
            ' retired=' + HandleTable.retiredCount().toString() + ' lastId=' + lastId.toString())
        @Assert(badRound, -1)
        @Assert(badId, 0)
        @Assert(unreadableRound, -1)
        // 1 个槽退休 + 1 个新槽接管 ⇒ 高水位恰增 2（含 0 号哨兵的基础值不变）。
        @Assert(HandleTable.slotCount(), base + 2)
        @Assert(HandleTable.retiredCount(), 1)
    }

    /** 退休槽的最后一个标识永久失效，且释放它不会误伤接管的新槽。 */
    @TestCase
    public func retiredSlotIdsStayDead(): Unit {
        HandleTable.resetForTest()
        var round = 0
        var lastBeforeRetire: Int64 = 0
        while (round < 32767) {
            HandleTable.openWindow(4)
            let id = HandleTable.pin('retire-probe')
            HandleTable.release(id)
            lastBeforeRetire = id
            HandleTable.resetWindow(-1)
            round = round + 1
        }
        // 第 32768 次分配必须落到新槽（旧槽已在上一轮释放时退休）。
        HandleTable.openWindow(4)
        let fresh = HandleTable.pin('retire-probe')
        HandleTable.resetWindow(-1)
        @Assert(fresh > 0, true)
        @Assert(HandleTable.retiredCount(), 1)
        @Assert(HandleTable.isLiveHandle(lastBeforeRetire), false)
        @Assert(HandleTable.getAny(lastBeforeRetire).isNone(), true)
        // 释放旧标识不得把新槽打成 dead。
        HandleTable.release(lastBeforeRetire)
        @Assert(HandleTable.isLiveHandle(fresh), true)
        @Assert(HandleTable.getAny(fresh).isSome(), true)
        HandleTable.release(fresh)
    }
}

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
package fountain::f_jit

import std.collection.ArrayList
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_jit.runtime.HandleTable
import fountain::f_jit.runtime.RuntimeEnv

/**
 * `HandleTable` 可调配置的并发回归（H4）。
 *
 * 1 线程在 `initialCapacity` 的两个合法值之间反复切换，3 线程同时开/关窗口。
 * 断言每次拿到的容量都是两个合法值之一、基址为正——即配置更新与窗口开启之间没有
 * 读到「半更新」的值。
 *
 * **注意**：8 B 对齐的普通读写在本机不会撕裂，旧实现也能通过本用例；它不构成对旧实现的
 * 变异证据（见 `verify.md`「可测性」一节）。本用例的价值是长期回归：
 * 任何把配置读取改成跨多次读取、或引入非对齐/多字段复合状态的改动，都会在这里露头。
 */
@Test
public class HandleTableConfigRace_test {
    @TestCase
    public func concurrentConfigUpdatesKeepWindowLegal(): Unit {
        HandleTable.resetForTest()
        let savedCap = HandleTable.initialCapacity
        let savedLimit = HandleTable.capacityLimit
        HandleTable.initialCapacity = 8
        HandleTable.capacityLimit = 1048576
        let fs = ArrayList<Future<Int64>>()
        // 1 线程：反复切换初始容量
        fs.add(spawn {
            var i = 0
            while (i < 3000) {
                HandleTable.initialCapacity = if (i % 2 == 0) { 8 } else { 32 }
                i = i + 1
            }
            0
        })
        // 3 线程：并发开窗 / 关窗
        var t = 0
        while (t < 3) {
            fs.add(spawn {
                let rs = RuntimeEnv.current()
                var bad = 0
                var i = 0
                while (i < 3000) {
                    let (base, cap) = HandleTable.openWindowWith(rs, 0)
                    if (cap != 8 && cap != 32) {
                        bad = bad + 1
                    }
                    if (base <= 0) {
                        bad = bad + 1
                    }
                    HandleTable.resetWindow(rs, -1)
                    i = i + 1
                }
                bad
            })
            t = t + 1
        }
        var bad = 0
        for (x in fs) {
            bad = bad + x.get()
        }
        @Assert(bad, 0)
        HandleTable.initialCapacity = savedCap
        HandleTable.capacityLimit = savedLimit
        HandleTable.resetForTest()
    }
}

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
package fountain::f_base

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.ArrayList
import std.sync.AtomicBool

@Test
public class FutureTask_test {
    /*
     * FT-1（bug-f_base.md §1.1）：构造任务后由创建线程写入 InheritedTaskLocal 的值，任务内必须读得到。
     * 修前：task 的 hashCode 取可变的 tid（构造期恒为 0），写入落在 hash=0 的桶，任务内按真实 tid 查不到。
     */
    @TestCase
    public func testLocalSetBeforeTaskRunsIsVisible(): Unit {
        let rounds = 200
        var lost = 0
        for (_ in 0..rounds) {
            let ready = AtomicBool(false)
            let slot = ArrayList<InheritedTaskLocal<Int64>>()
            let task = FutureTask<Int64>({ => futureTaskTestReadLocal(ready, slot) })
            let local = task.newLocal<Int64>()
            local.set(5)
            slot.add(local)
            ready.store(true)
            if (task.get() != 5) {
                lost++
            }
        }
        @Expect(lost, 0)
    }

    /*
     * FT-1（bug-f_base.md §1.1）：两个不同的任务必须互不相等。
     * 修前：hashCode/== 都取 tid，未启动时两者都是 0 ⇒ 不同任务被判为相等。
     */
    @TestCase
    public func testDistinctTasksAreNotEqualBeforeStart(): Unit {
        let rounds = 200
        var equalCount = 0
        for (_ in 0..rounds) {
            let a = FutureTask<Int64>({ => 1 })
            let b = FutureTask<Int64>({ => 1 })
            if (a == b) {
                equalCount++
            }
            let _ = a.get()
            let _ = b.get()
        }
        @Expect(equalCount, 0)
    }
}

private func futureTaskTestReadLocal(ready: AtomicBool, slot: ArrayList<InheritedTaskLocal<Int64>>): Int64 {
    while (!ready.load()) {}
    match (slot[0].get()) {
        case Some(x) => x
        case None => -1
    }
}

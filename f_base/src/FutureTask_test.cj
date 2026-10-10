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
import std.collection.concurrent.ConcurrentHashMap
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

    /*
     * FT-2（bug-f_base.md §1.2）：父任务创建子任务后立即结束（fire-and-forget，shutdownSubOnFinish 默认 true），
     * 子任务必须收到取消信号。
     * 修前：子任务只在"自己开始运行"时才登记进 subTasks，父任务的 finally 看不到它 ⇒ 漏取消。
     */
    @TestCase
    public func testChildCancelledWhenParentFinishesImmediately(): Unit {
        let rounds = 20
        var notCancelled = 0
        for (i in 0..rounds) {
            let box = ConcurrentHashMap<Int64, Bool>()
            let root = FutureTask<Unit>({ => futureTaskTestFireAndForgetParent(box, i) })
            let _ = root.get()
            sleep(400 * Duration.millisecond)
            match (box.get(i)) {
                case Some(b) => if (!b) {
                    notCancelled++
                }
                case None => notCancelled++
            }
        }
        @Expect(notCancelled, 0)
    }

    /*
     * FT-2（bug-f_base.md §1.2）：同一父任务的 4 个同类型子任务并发登记，父任务结束时必须**全部**被取消。
     * 修前：不同子任务各持一把自己的 mutex（互不互斥）+ 非线程安全 HashSet ⇒ 登记/迭代会丢（exp16 实测 15% 轮次部分丢失）。
     */
    @TestCase
    public func testConcurrentChildrenAllCancelled(): Unit {
        let rounds = 30
        var partial = 0
        let keys = [0, 1, 2, 3]
        for (_ in 0..rounds) {
            let box = ConcurrentHashMap<Int64, Bool>()
            let root = FutureTask<Unit>({ => futureTaskTestFourChildrenParent(box) })
            let _ = root.get()
            sleep(450 * Duration.millisecond)
            var cancelled = 0
            for (k in keys) {
                match (box.get(k)) {
                    case Some(b) => if (b) {
                        cancelled++
                    }
                    case None => ()
                }
            }
            if (cancelled != 4) {
                partial++
            }
        }
        @Expect(partial, 0)
    }

    /*
     * FT-2 的行为保持用例：shutdownSubOnFinish = false 时，父任务结束**不得**取消子任务。
     * （修前修后都应通过，用来防止"登记提前"的改动变成无条件取消。）
     */
    @TestCase
    public func testShutdownSubOnFinishFalseKeepsChildRunning(): Unit {
        var cancelled = 0
        for (i in 0..3) {
            let box = ConcurrentHashMap<Int64, Bool>()
            let root = FutureTask<Unit>(false, { => futureTaskTestFireAndForgetParent(box, i) })
            let _ = root.get()
            sleep(400 * Duration.millisecond)
            match (box.get(i)) {
                case Some(b) => if (b) {
                    cancelled++
                }
                case None => ()
            }
        }
        @Expect(cancelled, 0)
    }

    /*
     * FT-3（bug-f_base.md §2.1）：父任务结束时，子任务不因**泛型实参不同**而被跳过。
     * 修前：shutdownCurrentSubThreads 按 `FutureTask<T>` 模式匹配（T = 调用方实参），
     * 父任务 FutureTask<Unit> 的 FutureTask<Int64> 子任务被静默跳过（登记正常，只是不被取消）。
     */
    @TestCase
    public func testMixedTypeChildrenAreCancelledToo(): Unit {
        // 编译期 API 检查：README 记录的两个静态/实例入口仍能经 FutureTask<T> 调用
        // （FT-3 把实现移到了 AbstractFutureTask，这里确认继承解析没断）
        FutureTask<Unit>.shutdownCurrentSubThreads()
        var notCancelled = 0
        for (_ in 0..3) {
            let box = ConcurrentHashMap<String, Bool>()
            let root = FutureTask<Unit>({ => futureTaskTestMixedTypeParent(box) })
            let _ = root.get()
            sleep(400 * Duration.millisecond)
            for (k in ["same", "diff"]) {
                match (box.get(k)) {
                    case Some(b) => if (!b) {
                        notCancelled++
                    }
                    case None => notCancelled++
                }
            }
        }
        @Expect(notCancelled, 0)
    }
}

private func futureTaskTestReadLocal(ready: AtomicBool, slot: ArrayList<InheritedTaskLocal<Int64>>): Int64 {
    while (!ready.load()) {}
    match (slot[0].get()) {
        case Some(x) => x
        case None => -1
    }
}

private func futureTaskTestPollCancel(box: ConcurrentHashMap<Int64, Bool>, key: Int64): Unit {
    var i = 0
    while (i < 60) {
        if (Thread.currentThread.hasPendingCancellation) {
            break
        }
        sleep(5 * Duration.millisecond)
        i++
    }
    box.add(key, Thread.currentThread.hasPendingCancellation)
}

// 父任务：创建子任务后不等待，直接结束
private func futureTaskTestFireAndForgetParent(box: ConcurrentHashMap<Int64, Bool>, key: Int64): Unit {
    let _ = FutureTask<Unit>({ => futureTaskTestPollCancel(box, key) })
}

private func futureTaskTestSleepThenRecord(box: ConcurrentHashMap<Int64, Bool>, key: Int64): Unit {
    sleep(300 * Duration.millisecond)
    box.add(key, Thread.currentThread.hasPendingCancellation)
}

// 父任务：一次并发创建 4 个同类型子任务，等它们登记完再结束
private func futureTaskTestFourChildrenParent(box: ConcurrentHashMap<Int64, Bool>): Unit {
    let _ = FutureTask<Unit>({ => futureTaskTestSleepThenRecord(box, 0) })
    let _ = FutureTask<Unit>({ => futureTaskTestSleepThenRecord(box, 1) })
    let _ = FutureTask<Unit>({ => futureTaskTestSleepThenRecord(box, 2) })
    let _ = FutureTask<Unit>({ => futureTaskTestSleepThenRecord(box, 3) })
    sleep(150 * Duration.millisecond)
}

private func futureTaskTestPollCancelStr(box: ConcurrentHashMap<String, Bool>, key: String): Unit {
    var i = 0
    while (i < 60) {
        if (Thread.currentThread.hasPendingCancellation) {
            break
        }
        sleep(5 * Duration.millisecond)
        i++
    }
    box.add(key, Thread.currentThread.hasPendingCancellation)
}

private func futureTaskTestPollCancelStrI64(box: ConcurrentHashMap<String, Bool>, key: String): Int64 {
    futureTaskTestPollCancelStr(box, key)
    0
}

// 父任务：泛型实参为 Unit，同时创建 Unit 与 Int64 两种子任务
private func futureTaskTestMixedTypeParent(box: ConcurrentHashMap<String, Bool>): Unit {
    let _ = FutureTask<Unit>({ => futureTaskTestPollCancelStr(box, "same") })
    let _ = FutureTask<Int64>({ => futureTaskTestPollCancelStrI64(box, "diff") })
    sleep(150 * Duration.millisecond)
}

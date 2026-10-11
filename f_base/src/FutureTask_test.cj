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
import std.collection.HashSet
import std.collection.concurrent.ConcurrentHashMap
import std.sync.{AtomicBool, AtomicInt64}

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

    /*
     * FT-4（bug-f_base.md §2.2，路线 2）：`set` 只写"当前任务"这一层 —— 子任务的写不得改动 owner 的值，
     * 之后读取 owner 值的兄弟任务也看不到子任务的写。
     */
    @TestCase
    public func testChildSetDoesNotAffectOwner(): Unit {
        let box = ConcurrentHashMap<String, String>()
        let root = FutureTask<Unit>({ => futureTaskTestChildSetScope(box) })
        let _ = root.get()
        @Expect(box.get("child"), Some("2"))
        @Expect(box.get("owner"), Some("1")) // 修前会被子任务的写覆盖成 "2"
        @Expect(box.get("sibling"), Some("1")) // 修前同样是 "2"
    }

    /*
     * FT-4（路线 2）守卫：子任务写入的值必须能被它自己的后代读到（继承链不能因为"写当前任务"而断）。
     */
    @TestCase
    public func testChildSetVisibleToOwnDescendant(): Unit {
        let box = ConcurrentHashMap<String, String>()
        let root = FutureTask<Unit>({ => futureTaskTestChildSetForGrandChild(box) })
        let _ = root.get()
        @Expect(box.get("grand"), Some("2"))
    }

    /*
     * FT-4（路线 2）：owner 任务已结束（fire-and-forget）时，子任务 set 之后再 get 必须读回自己写的值。
     * 修前：写进 owner 的表（该任务已不在 taskMap 里）⇒ 自读为 None（EXP17）。
     */
    @TestCase
    public func testSetThenGetInTaskWorksAfterOwnerFinished(): Unit {
        let box = ConcurrentHashMap<String, String>()
        let root = FutureTask<Unit>({ => futureTaskTestSetAfterOwnerGone(box) })
        let _ = root.get()
        sleep(400 * Duration.millisecond)
        @Expect(box.get("self"), Some("9"))
    }

    /*
     * FT-4（路线 2）：`remove` 也只作用于当前任务这一层 —— 子任务 remove 不得清掉 owner 的值。
     */
    @TestCase
    public func testChildRemoveDoesNotClearOwner(): Unit {
        let box = ConcurrentHashMap<String, String>()
        let root = FutureTask<Unit>({ => futureTaskTestChildRemoveScope(box) })
        let _ = root.get()
        @Expect(box.get("childAfterRemove"), Some("1")) // 子任务 remove 后回退读到 owner 的 1
        @Expect(box.get("owner"), Some("1")) // 修前 owner 的槽会被子任务清掉 ⇒ None
    }

    /*
     * FT-4 口径钉住（决策第 3 条：getOrSet/getOrCompute 保持现状）：
     * 它们未命中时仍写"创建该 local 的任务"（子树共享槽），与 set 的"写当前任务"分工不同。
     */
    @TestCase
    public func testGetOrComputeStillPopulatesOwnerSlot(): Unit {
        let box = ConcurrentHashMap<String, String>()
        let root = FutureTask<Unit>({ => futureTaskTestGetOrComputeScope(box) })
        let _ = root.get()
        @Expect(box.get("childShared"), Some("42"))
        @Expect(box.get("ownerShared"), Some("42")) // getOrCompute 仍落 owner 共享槽
        @Expect(box.get("childOwn"), Some("2"))
        @Expect(box.get("ownerOwn"), Some("1")) // 而 set 只写当前任务 ⇒ owner 不受影响
    }

    /*
     * FT-4 二次决策（bug-f_base.md §2.2）：getOrSet/getOrCompute 改用**二段检查锁** ——
     * 并发调用方里只有一个会执行 fn 并写入，其余在锁内复查后拿到同一个值。
     * 修前：所有调用方都在第一次（无锁）检查时未命中 ⇒ 各自算一次、各自返回自己那份。
     */
    @TestCase
    public func testGetOrComputeComputesOnceUnderConcurrency(): Unit {
        let n = 8
        let computeCount = AtomicInt64(0)
        let got = ConcurrentHashMap<Int64, Int64>()
        let root = FutureTask<Unit>({ => futureTaskTestDclParent(n, computeCount, got) })
        let _ = root.get()
        @Expect(computeCount.load(), 1) // 修前为 8
        var first = -1
        var allSame = true
        for (i in 0..n) {
            match (got.get(i)) {
                case Some(v) => if (first < 0) {
                    first = v
                } else if (v != first) {
                    allSame = false
                }
                case None => allSame = false
            }
        }
        @Expect(allSame, true) // 修前各拿到自己那份（值不同）
        @Expect(first >= 1, true)
    }

    /*
     * 守卫：链上已有值时 getOrCompute 不得再算、也不得覆盖（修前修后都应通过）。
     */
    @TestCase
    public func testGetOrComputeDoesNotComputeWhenValueExists(): Unit {
        let box = ConcurrentHashMap<String, String>()
        let root = FutureTask<Unit>({ => futureTaskTestGetOrComputeExisting(box) })
        let _ = root.get()
        @Expect(box.get("child"), Some("7"))
        @Expect(box.get("count"), Some("0"))
        @Expect(box.get("owner"), Some("7"))
    }

    /*
     * FT-3 遗留收口：类型无关的 AbstractFutureTask.current() 与按 T 取的那个指向同一个任务，
     * 且拿到的句柄可直接 newLocal 使用。
     */
    @TestCase
    public func testCurrentTypeAgnosticHandleMatchesTypedHandle(): Unit {
        let box = ConcurrentHashMap<String, String>()
        let t = FutureTask<Int64>({ => futureTaskTestCurrentInTask(box) })
        let _ = t.get()
        @Expect(box.get("same"), Some("true"))
        @Expect(box.get("roundTrip"), Some("5"))
    }

    /*
     * FT-3 遗留收口：泛型实参不一致时抛的异常必须能说明"实参问题"（旧消息是误导性的
     * "No task found in current thread"），且可按 FutureTaskException 类型捕获。
     */
    @TestCase
    public func testCurrentWithWrongTypeArgumentThrowsWithPreciseMessage(): Unit {
        let box = ConcurrentHashMap<String, String>()
        let t = FutureTask<Int64>({ => futureTaskTestCurrentWrongType(box) })
        let _ = t.get()
        @Expect(box.get("messageMentionsType"), Some("true"))
        @Expect(box.get("caughtTyped"), Some("true"))
    }

    /*
     * FT-3 遗留收口：不在任务里（测试线程）时 currentOrNone() 得 None、current() 抛 FutureTaskException。
     */
    @TestCase
    public func testCurrentOrNoneOutsideTaskIsNone(): Unit {
        let n = AbstractFutureTask.currentOrNone()
        var isNone = false
        match (n) {
            case Some(_) => ()
            case None => isNone = true
        }
        @Expect(isNone, true)
        var threw = false
        try {
            let _ = AbstractFutureTask.current()
        } catch (e: FutureTaskException) {
            threw = true
        }
        @Expect(threw, true)
    }

    /*
     * 守卫：不在任务里调 FutureTask<T>.current() 仍须抛异常（既有行为不变）。
     */
    @TestCase
    public func testCurrentOutsideTaskThrows(): Unit {
        var threw = false
        try {
            let _ = FutureTask<Unit>.current()
        } catch (e: FutureTaskException) {
            threw = true
        }
        @Expect(threw, true)
    }

    /*
     * FT-5（bug-f_base.md §2.3，作者定性为缺陷）：父任务先结束（fire-and-forget）后，
     * 已创建的子任务仍应沿父链继承到它的值。
     * 修前：链式查找依赖 taskMap（父任务结束即摘除）⇒ 读到 None。
     */
    @TestCase
    public func testChildInheritsAfterParentFinished(): Unit {
        let box = ConcurrentHashMap<String, String>()
        let root = FutureTask<Unit>({ => futureTaskTestInheritAfterParentGone(box) })
        let _ = root.get()
        sleep(400 * Duration.millisecond)
        @Expect(box.get("child"), Some("7"))
    }

    /*
     * FT-5 强化：**两级祖先都已结束**时，孙任务仍能读到根任务的值（沿父链跨过两个已结束的节点）。
     */
    @TestCase
    public func testGrandChildInheritsAcrossFinishedAncestors(): Unit {
        let box = ConcurrentHashMap<String, String>()
        let root = FutureTask<Unit>({ => futureTaskTestInheritAcrossTwoGone(box) })
        let _ = root.get()
        sleep(600 * Duration.millisecond)
        @Expect(box.get("grand"), Some("7"))
    }

    /*
     * FT-5 守卫：父任务存活时，**它之后**写入的值也必须能被已创建的子任务读到
     * （继承是活的引用，不是"构造期快照/拷贝"）。
     */
    @TestCase
    public func testChildSeesParentValueWrittenAfterCreation(): Unit {
        let box = ConcurrentHashMap<String, String>()
        let root = FutureTask<Unit>({ => futureTaskTestLateParentWrite(box) })
        let _ = root.get()
        @Expect(box.get("child"), Some("7"))
    }

    /*
     * FT-6 ⑥+①（bug-f_base.md §2.4 量化）：owner 一张 local 表都没有时，多个子任务并发向它
     * 写**不同的** local —— 表是懒建的，且建在 owner 身上，必须只建一张、不丢任何一侧的写入
     * （否则"不建表就不花那 3.6~5.2µs"这条优化会变成静默丢值）。
     */
    @TestCase
    public func testConcurrentChildrenCreateOwnerMapLazily(): Unit {
        let box = ConcurrentHashMap<String, String>()
        let root = FutureTask<Unit>({ => futureTaskTestLazyOwner(box) })
        let _ = root.get()
        @Expect(box.get("owner0"), Some("10"))
        @Expect(box.get("owner1"), Some("20"))
        @Expect(box.get("owner2"), Some("30"))
        @Expect(box.get("later"), Some("10,20,30"))
    }

    /*
     * FT-6 ③ 守卫：叶子任务（不创建子任务）不会在自己的 tid 下留下桶 ——
     * "没登记过 ⇒ 没有桶"正是 teardown 短路清理（`hasChildren`）的正确性前提。
     */
    @TestCase
    public func testLeafTaskCreatesNoSubTaskBucket(): Unit {
        let box = ConcurrentHashMap<String, Int64>()
        let leaf = FutureTask<Int64>({ => futureTaskTestLeafTid(box) })
        let _ = leaf.get()
        let tid = box.get("tid")
        @Expect(tid.isSome(), true)
        match (tid) {
            case Some(t) => @Expect(AbstractFutureTask.subTasks.get(t).isNone(), true)
            case None => ()
        }
    }
}

private func futureTaskTestReadLocal(ready: AtomicBool, slot: ArrayList<InheritedTaskLocal<Int64>>): Int64 {
    while (!ready.load()) {}
    match (slot[0].get()) {
        case Some(x) => x
        case None => -1
    }
}

// ===== FT-6 ③（叶子任务不建桶）的辅助函数 =====

private func futureTaskTestLeafTid(box: ConcurrentHashMap<String, Int64>): Int64 {
    box.add("tid", Thread.currentThread.id)
    1
}

// ===== FT-6 ⑥+①（并发懒建 owner 的 local 表）的辅助函数 =====

private func futureTaskTestLazyWriteChild(local: InheritedTaskLocal<Int64>, value: Int64): Unit {
    sleep(30 * Duration.millisecond) // 对齐起跑线，让三个子任务尽量同时走到"首次建表"
    local.getOrSet(value) // 未命中 ⇒ 进 initLock 复查后写入 owner 的表（首次会建表）
}

private func futureTaskTestLocalStr(local: InheritedTaskLocal<Int64>): String {
    match (local.get()) {
        case Some(v) => "${v}"
        case None => "None"
    }
}

private func futureTaskTestReadThree(box: ConcurrentHashMap<String, String>, l0: InheritedTaskLocal<Int64>, l1: InheritedTaskLocal<Int64>, l2: InheritedTaskLocal<Int64>): Unit {
    box.add("later", futureTaskTestLocalStr(l0) + "," + futureTaskTestLocalStr(l1) + "," + futureTaskTestLocalStr(l2))
}

private func futureTaskTestLazyOwner(box: ConcurrentHashMap<String, String>): Unit {
    let me = FutureTask<Unit>.current()
    let l0 = me.newLocal<Int64>()
    let l1 = me.newLocal<Int64>()
    let l2 = me.newLocal<Int64>()
    let c0 = FutureTask<Unit>({ => futureTaskTestLazyWriteChild(l0, 10) })
    let c1 = FutureTask<Unit>({ => futureTaskTestLazyWriteChild(l1, 20) })
    let c2 = FutureTask<Unit>({ => futureTaskTestLazyWriteChild(l2, 30) })
    let _ = c0.get()
    let _ = c1.get()
    let _ = c2.get()
    // 从 owner 自己这一层读回（三个值都应落在 owner 的那张表里）
    box.add("owner0", futureTaskTestLocalStr(l0))
    box.add("owner1", futureTaskTestLocalStr(l1))
    box.add("owner2", futureTaskTestLocalStr(l2))
    // 注意：本函数返回后 owner 结束，届时会取消 c0/c1/c2（都已 get 过，取消对已完成任务无副作用）；
    // 所以"之后创建的后代"要在这里创建 —— 它同样应读到 owner 表里的这三个值。
    let later = FutureTask<Unit>({ => futureTaskTestReadThree(box, l0, l1, l2) })
    let _ = later.get()
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

// ===== FT-4（路线 2）的辅助函数 =====

private func futureTaskTestReadStr(local: InheritedTaskLocal<Int64>): String {
    match (local.get()) {
        case Some(x) => "${x}"
        case None => "None"
    }
}

// 子任务 set(2) 后自读；随后父任务、以及"子任务结束之后才创建的兄弟"各读一次
private func futureTaskTestChildSetScope(box: ConcurrentHashMap<String, String>): Unit {
    let me = FutureTask<Unit>.current()
    let local = me.newLocal<Int64>()
    local.set(1)
    let child = FutureTask<Unit>({ => futureTaskTestChildSetSelf(box, local) })
    let _ = child.get()
    let sibling = FutureTask<Unit>({ => box.add("sibling", futureTaskTestReadStr(local)) })
    let _ = sibling.get()
    box.add("owner", futureTaskTestReadStr(local))
}

private func futureTaskTestChildSetSelf(box: ConcurrentHashMap<String, String>, local: InheritedTaskLocal<Int64>): Unit {
    local.set(2)
    box.add("child", futureTaskTestReadStr(local))
}

// 子任务 set(2)，再由它的子任务（孙）读
private func futureTaskTestChildSetForGrandChild(box: ConcurrentHashMap<String, String>): Unit {
    let me = FutureTask<Unit>.current()
    let local = me.newLocal<Int64>()
    local.set(1)
    let child = FutureTask<Unit>({ => futureTaskTestChildSetThenSpawnGrand(box, local) })
    let _ = child.get()
}

private func futureTaskTestChildSetThenSpawnGrand(box: ConcurrentHashMap<String, String>, local: InheritedTaskLocal<Int64>): Unit {
    local.set(2)
    let grand = FutureTask<Unit>({ => box.add("grand", futureTaskTestReadStr(local)) })
    let _ = grand.get()
}

// 父任务不等待子任务，直接结束（owner 已结束）；子任务 set(9) 后自读
private func futureTaskTestSetAfterOwnerGone(box: ConcurrentHashMap<String, String>): Unit {
    let me = FutureTask<Unit>.current()
    let local = me.newLocal<Int64>()
    local.set(1)
    let _ = FutureTask<Unit>({ => futureTaskTestSetThenReadSelf(box, local) })
}

private func futureTaskTestSetThenReadSelf(box: ConcurrentHashMap<String, String>, local: InheritedTaskLocal<Int64>): Unit {
    sleep(50 * Duration.millisecond) // 确保 owner 的 finally 已经摘掉 taskMap 登记
    local.set(9)
    box.add("self", futureTaskTestReadStr(local))
}

// 子任务 remove 之后再读；父任务随后读
private func futureTaskTestChildRemoveScope(box: ConcurrentHashMap<String, String>): Unit {
    let me = FutureTask<Unit>.current()
    let local = me.newLocal<Int64>()
    local.set(1)
    let child = FutureTask<Unit>({ => futureTaskTestRemoveThenRead(box, local) })
    let _ = child.get()
    box.add("owner", futureTaskTestReadStr(local))
}

private func futureTaskTestRemoveThenRead(box: ConcurrentHashMap<String, String>, local: InheritedTaskLocal<Int64>): Unit {
    local.remove()
    box.add("childAfterRemove", futureTaskTestReadStr(local))
}

// getOrCompute（子树共享槽，保持现状）与 set（当前任务）的分工对照
private func futureTaskTestGetOrComputeScope(box: ConcurrentHashMap<String, String>): Unit {
    let me = FutureTask<Unit>.current()
    let shared = me.newLocal<Int64>()
    let ownSet = me.newLocal<Int64>()
    ownSet.set(1)
    let child = FutureTask<Unit>({ => futureTaskTestChildSharedAndOwn(box, shared, ownSet) })
    let _ = child.get()
    box.add("ownerShared", futureTaskTestReadStr(shared))
    box.add("ownerOwn", futureTaskTestReadStr(ownSet))
}

private func futureTaskTestChildSharedAndOwn(box: ConcurrentHashMap<String, String>, shared: InheritedTaskLocal<Int64>, ownSet: InheritedTaskLocal<Int64>): Unit {
    box.add("childShared", "${shared.getOrCompute({ => 42 })}")
    ownSet.set(2)
    box.add("childOwn", futureTaskTestReadStr(ownSet))
}

// ===== 二段检查锁的辅助函数 =====

private func futureTaskTestDclCompute(count: AtomicInt64): Int64 {
    let n = count.fetchAdd(1) + 1
    sleep(20 * Duration.millisecond) // 放大"检查 → 写入"的窗口，让并发各算一次暴露出来
    n
}

private func futureTaskTestDclChild(i: Int64, local: InheritedTaskLocal<Int64>, count: AtomicInt64,
                                    got: ConcurrentHashMap<Int64, Int64>, arrived: AtomicInt64, gate: AtomicBool): Unit {
    arrived.fetchAdd(1)
    while (!gate.load()) {} // 等所有兄弟就位后一起抢
    got.add(i, local.getOrCompute({ => futureTaskTestDclCompute(count) }))
}

// 父任务保持存活（等所有子任务结束）：这样 owner 的共享槽在链上可达，DCL 才能让其余调用方复查命中
private func futureTaskTestDclParent(n: Int64, count: AtomicInt64, got: ConcurrentHashMap<Int64, Int64>): Unit {
    let me = FutureTask<Unit>.current()
    let local = me.newLocal<Int64>()
    let arrived = AtomicInt64(0)
    let gate = AtomicBool(false)
    let kids = ArrayList<FutureTask<Unit>>()
    for (i in 0..n) {
        kids.add(FutureTask<Unit>({ => futureTaskTestDclChild(i, local, count, got, arrived, gate) }))
    }
    while (arrived.load() < n) {
        sleep(1 * Duration.millisecond)
    }
    gate.store(true)
    for (k in kids) {
        let _ = k.get()
    }
}

private func futureTaskTestGetOrComputeExistingChild(local: InheritedTaskLocal<Int64>, count: AtomicInt64, box: ConcurrentHashMap<String, String>): Unit {
    box.add("child", "${local.getOrCompute({ => futureTaskTestDclCompute(count) })}")
    box.add("count", "${count.load()}")
}

private func futureTaskTestGetOrComputeExisting(box: ConcurrentHashMap<String, String>): Unit {
    let me = FutureTask<Unit>.current()
    let local = me.newLocal<Int64>()
    local.set(7)
    let c = FutureTask<Unit>({ => futureTaskTestGetOrComputeExistingChild(local, AtomicInt64(0), box) })
    let _ = c.get()
    box.add("owner", futureTaskTestReadStr(local))
}

// ===== current() 收口的辅助函数 =====

private func futureTaskTestCurrentInTask(box: ConcurrentHashMap<String, String>): Int64 {
    let agnostic = AbstractFutureTask.current()
    let typed = FutureTask<Int64>.current()
    box.add("same", "${agnostic == typed}")
    let local = agnostic.newLocal<Int64>() // 类型无关的句柄也能建 local
    local.set(5)
    box.add("roundTrip", futureTaskTestReadStr(local))
    0
}

private func futureTaskTestCurrentWrongType(box: ConcurrentHashMap<String, String>): Int64 {
    var mentions = false
    try {
        let _ = FutureTask<Unit>.current() // 当前线程跑的是 FutureTask<Int64>
    } catch (e: Exception) {
        mentions = e.message.contains("type argument")
    }
    box.add("messageMentionsType", "${mentions}")
    var caughtTyped = false
    try {
        let _ = FutureTask<Unit>.current()
    } catch (e: FutureTaskException) {
        caughtTyped = true
    }
    box.add("caughtTyped", "${caughtTyped}")
    0
}

// ===== FT-5（父任务先结束仍可继承）的辅助函数 =====

// 父任务 set(7) 后立即结束；子任务等父任务的 finally 摘掉 taskMap 项之后再读
private func futureTaskTestInheritAfterParentGone(box: ConcurrentHashMap<String, String>): Unit {
    let me = FutureTask<Unit>.current()
    let local = me.newLocal<Int64>()
    local.set(7)
    let _ = FutureTask<Unit>({ => futureTaskTestReadAfterOwnerGone(box, local) })
}

private func futureTaskTestReadAfterOwnerGone(box: ConcurrentHashMap<String, String>, local: InheritedTaskLocal<Int64>): Unit {
    sleep(50 * Duration.millisecond)
    box.add("child", futureTaskTestReadStr(local))
}

// 根 set(7) → 中间层结束 → 孙任务在两个祖先都结束之后读
private func futureTaskTestInheritAcrossTwoGone(box: ConcurrentHashMap<String, String>): Unit {
    let me = FutureTask<Unit>.current()
    let local = me.newLocal<Int64>()
    local.set(7)
    let child = FutureTask<Unit>({ => futureTaskTestMiddleAndGrand(box, local) })
    let _ = child.get() // 只等中间层结束；根任务随之结束
}

private func futureTaskTestMiddleAndGrand(box: ConcurrentHashMap<String, String>, local: InheritedTaskLocal<Int64>): Unit {
    let _ = FutureTask<Unit>({ => futureTaskTestGrandReadAfterDelay(box, local) })
    // 中间层不等待孙任务，直接结束
}

private func futureTaskTestGrandReadAfterDelay(box: ConcurrentHashMap<String, String>, local: InheritedTaskLocal<Int64>): Unit {
    sleep(100 * Duration.millisecond)
    box.add("grand", futureTaskTestReadStr(local))
}

// 守卫：子任务创建**之后**父任务才写值，子任务（经闸门同步）应当读到
private func futureTaskTestLateParentWrite(box: ConcurrentHashMap<String, String>): Unit {
    let me = FutureTask<Unit>.current()
    let local = me.newLocal<Int64>()
    let gate = AtomicBool(false)
    let child = FutureTask<Unit>({ => futureTaskTestReadAfterGate(box, local, gate) })
    local.set(7)
    gate.store(true)
    let _ = child.get()
}

private func futureTaskTestReadAfterGate(box: ConcurrentHashMap<String, String>, local: InheritedTaskLocal<Int64>, gate: AtomicBool): Unit {
    while (!gate.load()) {}
    box.add("child", futureTaskTestReadStr(local))
}

// ===== FT-4 辅助函数结束 =====

/*
Copyright (c) 2025 WuJingrun（吴京润）

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
package fountain::f_ticktock

import std.collection.{ArrayList, HashSet}
import std.sync.{AtomicInt64, Condition, Mutex}
import std.time.Month
import std.unittest.*
import std.unittest.testmacro.*

/** 端到端用例统一使用的表达式：秒=1 分=2 时=3 日=4 月=5，真实时间几乎不可能命中。 */
let INDEX_TEST_CRON = "1 2 3 4 5 *"

func indexTestTime(year: Int64, month: Int64, day: Int64, hour: Int64, minute: Int64, second: Int64): DateTime {
    DateTime.of(
        year: year, month: Month.of(month), dayOfMonth: day, hour: hour, minute: minute, second: second)
}

let INDEX_TEST_TIME = indexTestTime(2026, 5, 4, 3, 2, 1)

func indexTestWaitUntil(condition: () -> Bool, timeout: Duration): Unit {
    let deadline = DateTime.now() + timeout
    while (!condition() && DateTime.now() < deadline) {
        sleep(10 * Duration.millisecond)
    }
}

/**
 * 时间索引与 emit 候选语义的回归用例（性能基准测试与优化方案 §5.4）。
 *
 * 核心不变量：对任意表达式与任意时间点，
 *   {任务 | 精确匹配 matches(now)} ⊆ {索引候选 candidates(now)}
 * 即索引允许"多算候选"，绝不允许漏掉任何真实命中；
 * 命中判定与执行语义（once / 不可并发跳过 / 移除与同名替换）与旧实现一致。
 *
 * 注意：端到端用例使用 Ticktock 单例（进程内共享），任务名互不相同，
 * 表达式选定在真实时间几乎不可能命中的值（避免后台节拍线程干扰）。
 */
@Test
public class TicktockIndex_test {
    /** 覆盖 §5.4 要求的表达式形态：全通配 / 单值 / 区间 / 步长 / L / 列表 / 多表达式 / 年约束 / 省略尾字段。 */
    private static let EXPRS = [
        "* * * * * *",
        "1/3-45 * * * * *",
        "0/5-30 0-5 1/2 L * 1,3/2-5,7",
        "0 0 3 29 2 *",
        "L * * * * *",
        "1,3,5 * * * * *",
        "0 0 0 L 2 *",
        "30 30 1 L 1,3,5,7,8,10,12 *",
        "0 0 0 * * *",
        "* * * * * L",
        "1/3-45 * * * * * | 0 0 3 29 2 *",
        "10-20,25/5-40 0 * * * *"
    ]

    /** 覆盖普通时刻 / 月末 / 闰日 / 年初年末 / 年约束 / 无上限年份。 */
    private static let TIMES = [
        indexTestTime(2026, 10, 14, 10, 30, 0),
        indexTestTime(2026, 10, 14, 10, 30, 1),
        indexTestTime(2026, 10, 14, 10, 30, 43),
        indexTestTime(2026, 10, 14, 10, 30, 45),
        indexTestTime(2026, 10, 14, 10, 30, 59),
        indexTestTime(2026, 10, 31, 23, 59, 59),
        indexTestTime(2026, 11, 30, 23, 59, 59),
        indexTestTime(2026, 2, 28, 3, 0, 0),
        indexTestTime(2028, 2, 28, 3, 0, 0),
        indexTestTime(2028, 2, 29, 3, 0, 0),
        indexTestTime(2026, 11, 1, 0, 0, 0),
        indexTestTime(2026, 1, 1, 0, 0, 0),
        indexTestTime(2026, 1, 31, 0, 0, 0),
        indexTestTime(2026, 12, 31, 0, 0, 0),
        indexTestTime(2030, 1, 1, 0, 0, 0),
        indexTestTime(2030, 1, 1, 0, 0, 1),
        indexTestTime(2030, 6, 15, 12, 0, 0),
        indexTestTime(2031, 1, 1, 0, 0, 0),
        indexTestTime(2046, 1, 1, 0, 0, 0),
        indexTestTime(2046, 6, 4, 3, 2, 1)
    ]

    /**
     * 索引等价性对拍：任意 matches 命中的任务必须出现在候选集合中
     * （索引只做排除，不允许漏命中）。
     */
    @TestCase
    public func testIndexCandidatesSupersetOfMatches(): Unit {
        let index = TicktockIndex()
        let compiled = ArrayList<Collection<CronDataCollection>>()
        for (i in 0..EXPRS.size) {
            let crons = CronCompiler.compile(EXPRS[i])
            compiled.add(crons)
            for (cron in crons) {
                index.add(i, cron)
            }
        }
        let buffer = ArrayList<Int64>()
        var hits = 0
        for (time in TIMES) {
            index.candidates(time, buffer)
            let candidates = HashSet<Int64>()
            for (id in buffer) {
                candidates.add(id)
            }
            for (i in 0..EXPRS.size) {
                var hit = false
                for (cron in compiled[i] where cron.matches(time)) {
                    hit = true
                    break
                }
                if (hit) {
                    hits += 1
                    @Assert(candidates.contains(i))
                }
            }
        }
        // 对拍数据必须真的产生过命中，否则本用例是空转的
        @Assert(hits > 0)
    }

    /** L 任务进 dynamic：任意 tick 都不被静态值桶漏掉。 */
    @TestCase
    public func testLastTaskIsAlwaysCandidate(): Unit {
        let index = TicktockIndex()
        let crons = CronCompiler.compile("L * * * * *")
        for (cron in crons) {
            index.add(0, cron)
        }
        let buffer = ArrayList<Int64>()
        for (time in TIMES) {
            index.candidates(time, buffer)
            var found = false
            for (id in buffer where id == 0) {
                found = true
                break
            }
            @Assert(found)
        }
    }

    /**
     * 年字段：被约束时进 dynamic（不为年份建值桶、每 tick 参与判定、绝不漏）；
     * 未被约束时保持"无上限"语义（未来任意年份都能命中）。
     *
     * 注意：现有 CronCompiler 的字段正则只接受 1~2 位数字，年份约束形式
     * （如 2030）当前无法通过表达式编译，这里直接构造 CronData 数据，
     * 用于锁定索引对"年约束"的保守处理行为。
     */
    @TestCase
    public func testYearConstrainedAndNoUpperLimit(): Unit {
        let index = TicktockIndex()
        let dated = CronDataCollection("* * * * * * 2030")
        dated.put(TicktockUnit.YEARLY, CronData(TicktockUnit.YEARLY, 2030))
        index.add(7, dated)
        let buffer = ArrayList<Int64>()
        let hit2030 = indexTestTime(2030, 1, 1, 0, 0, 0)
        index.candidates(hit2030, buffer)
        var found = false
        for (id in buffer where id == 7) {
            found = true
            break
        }
        @Assert(found)
        @Assert(dated.matches(hit2030))
        // 2031 年不命中；且年约束任务始终在候选里（dynamic 保守包含）
        let miss2031 = indexTestTime(2031, 1, 1, 0, 0, 0)
        @Assert(!dated.matches(miss2031))
        index.candidates(miss2031, buffer)
        var found2031 = false
        for (id in buffer where id == 7) {
            found2031 = true
            break
        }
        @Assert(found2031)
        // 年字段省略 = 无上限：2046 年仍然命中且候选
        let index2 = TicktockIndex()
        let crons2 = CronCompiler.compile("0 0 0 1 1 *")
        for (cron in crons2) {
            index2.add(8, cron)
        }
        let hit2046 = indexTestTime(2046, 1, 1, 0, 0, 0)
        var matched2046 = false
        for (cron in crons2 where cron.matches(hit2046)) {
            matched2046 = true
            break
        }
        @Assert(matched2046)
        index2.candidates(hit2046, buffer)
        var found2046 = false
        for (id in buffer where id == 8) {
            found2046 = true
            break
        }
        @Assert(found2046)
    }

    /** once 任务：执行一次后被移除，再触发不执行。 */
    @TestCase
    public func testOnceTaskRemovedAfterExecution(): Unit {
        let launcher = Ticktock.instance
        let name = "TicktockIndex_test.once"
        let task = IndexOnceTask(name)
        launcher.addOrReplaceTask(task, INDEX_TEST_CRON)
        launcher.emit(INDEX_TEST_TIME)
        indexTestWaitUntil({=> task.executed.load() == 1}, 5 * Duration.second)
        @Assert(task.executed.load() == 1)
        launcher.emit(INDEX_TEST_TIME)
        sleep(500 * Duration.millisecond)
        @Assert(task.executed.load() == 1)
        launcher.removeTask(name)
    }

    /** 不可并发任务：上次未结束则跳过本次。 */
    @TestCase
    public func testNonConcurrentableSkipsWhileRunning(): Unit {
        let launcher = Ticktock.instance
        let name = "TicktockIndex_test.blocking"
        let task = IndexBlockingTask(name)
        launcher.addOrReplaceTask(task, INDEX_TEST_CRON)
        launcher.emit(INDEX_TEST_TIME)
        task.waitEntered(5 * Duration.second)
        @Assert(task.executed.load() == 1)
        launcher.emit(INDEX_TEST_TIME)
        sleep(500 * Duration.millisecond)
        @Assert(task.executed.load() == 1)
        task.release()
        sleep(500 * Duration.millisecond)
        launcher.removeTask(name)
    }

    /** removeTask 后索引不再命中；同名替换后旧表达式失效、新表达式生效。 */
    @TestCase
    public func testRemoveTaskAndSameNameReplace(): Unit {
        let launcher = Ticktock.instance
        let removed = IndexCountingTask("TicktockIndex_test.removed")
        launcher.addOrReplaceTask(removed, INDEX_TEST_CRON)
        launcher.removeTask("TicktockIndex_test.removed")
        launcher.emit(INDEX_TEST_TIME)
        sleep(500 * Duration.millisecond)
        @Assert(removed.executed.load() == 0)

        let old = IndexCountingTask("TicktockIndex_test.replaced")
        let fresh = IndexCountingTask("TicktockIndex_test.replaced")
        launcher.addOrReplaceTask(old, INDEX_TEST_CRON)
        launcher.addOrReplaceTask(fresh, "0 0 0 1 1 *")
        launcher.emit(INDEX_TEST_TIME)
        sleep(500 * Duration.millisecond)
        @Assert(old.executed.load() == 0)
        @Assert(fresh.executed.load() == 0)

        launcher.addOrReplaceTask(fresh, INDEX_TEST_CRON)
        launcher.emit(INDEX_TEST_TIME)
        indexTestWaitUntil({=> fresh.executed.load() == 1}, 5 * Duration.second)
        @Assert(fresh.executed.load() == 1)
        launcher.removeTask("TicktockIndex_test.replaced")
    }

    /** 动态增删与 tick 并发：不崩溃、不移除后误命中、留存任务照常执行。 */
    @TestCase
    public func testConcurrentAddRemoveWhileEmitting(): Unit {
        let launcher = Ticktock.instance
        let count = 20
        let tasks = ArrayList<IndexCountingTask>()
        for (i in 0..count) {
            let task = IndexCountingTask("TicktockIndex_test.concurrent.${i}")
            tasks.add(task)
            launcher.addOrReplaceTask(task, INDEX_TEST_CRON)
        }
        let emitter = spawn {
            for (i in 0..100) {
                launcher.emit(INDEX_TEST_TIME)
            }
        }
        for (i in 0..count where i % 2 == 0) {
            launcher.removeTask(tasks[i].name)
        }
        emitter.get()
        sleep(800 * Duration.millisecond)
        // 留存任务应被执行过
        for (i in 0..count where i % 2 == 1) {
            @Assert(tasks[i].executed.load() >= 1)
        }
        // 已移除任务：后续 tick 不得再命中
        let baselines = ArrayList<Int64>()
        for (i in 0..count where i % 2 == 0) {
            baselines.add(tasks[i].executed.load())
        }
        for (i in 0..100) {
            launcher.emit(INDEX_TEST_TIME)
        }
        sleep(800 * Duration.millisecond)
        var index = 0
        for (i in 0..count where i % 2 == 0) {
            @Assert(tasks[i].executed.load() == baselines[index])
            index += 1
        }
        for (i in 0..count) {
            launcher.removeTask(tasks[i].name)
        }
    }
}

class IndexCountingTask <: TicktockTask {
    private let taskName: String
    let executed = AtomicInt64(0)

    init(taskName: String) {
        this.taskName = taskName
    }

    public prop name: String {
        get() {
            taskName
        }
    }

    public func execute(): Unit {
        executed.fetchAdd(1)
    }
}

class IndexOnceTask <: TicktockTask {
    private let taskName: String
    let executed = AtomicInt64(0)

    init(taskName: String) {
        this.taskName = taskName
    }

    public prop name: String {
        get() {
            taskName
        }
    }

    public prop once: Bool {
        get() {
            true
        }
    }

    public func execute(): Unit {
        executed.fetchAdd(1)
    }
}

class IndexBlockingTask <: TicktockTask {
    private let taskName: String
    let executed = AtomicInt64(0)
    private let enteredLock = Mutex()
    private let enteredCondition: Condition
    private let releaseLock = Mutex()
    private let releaseCondition: Condition
    private var entered_ = false
    private var released = false

    init(taskName: String) {
        this.taskName = taskName
        enteredCondition = synchronized(enteredLock) {
            enteredLock.condition()
        }
        releaseCondition = synchronized(releaseLock) {
            releaseLock.condition()
        }
    }

    public prop name: String {
        get() {
            taskName
        }
    }

    public func execute(): Unit {
        executed.fetchAdd(1)
        synchronized(enteredLock) {
            entered_ = true
            enteredCondition.notifyAll()
        }
        synchronized(releaseLock) {
            while (!released) {
                releaseCondition.wait()
            }
        }
    }

    func waitEntered(timeout: Duration): Unit {
        synchronized(enteredLock) {
            while (!entered_) {
                enteredCondition.wait(timeout: timeout)
            }
        }
    }

    func release(): Unit {
        synchronized(releaseLock) {
            released = true
            releaseCondition.notifyAll()
        }
    }
}

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
package fountain::f_ticktock

// `@TicktockTasks` 生成的代码落在本文件：需要 HashMap（任务表）、lookup（取 bean 实例）
// 与 BeanFactory（宏注入的 @Bean 展开后调用它注册）。
import std.collection.HashMap
import std.sync.AtomicInt64
import std.time.Month
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_bean.{BeanFactory, lookup, lookupOption}
import fountain::f_ticktock.macros.*

/**
 * 用例统一使用的表达式与时刻：闰日 2032-02-29 03:02:01，真实时间不会命中，避免后台节拍线程干扰。
 * 注意 cron 的年字段只接受 1~2 位数字（`CronCompiler.SINGLE`），所以表达式里不写年。
 */
let TICKTOCK_TASKS_CRON = "1 2 3 29 2 *"

let TICKTOCK_TASKS_TIME: DateTime = DateTime.of(
    year: 2032, month: Month.of(2), dayOfMonth: 29, hour: 3, minute: 2, second: 1)

/** once 用例单独用另一时刻，避免被其它用例的 emit 提前触发（once 任务执行后即被摘除）。 */
let TICKTOCK_TASKS_ONCE_CRON = "5 6 7 29 2 *"

let TICKTOCK_TASKS_ONCE_TIME: DateTime = DateTime.of(
    year: 2032, month: Month.of(2), dayOfMonth: 29, hour: 7, minute: 6, second: 5)

/** `DelayedPeriodic` 是普通 enum（未实现 Equatable），用 case 名做可读断言。 */
func ticktockTasksPeriodicName(periodic: DelayedPeriodic): String {
    match (periodic) {
        case DelayedPeriodic.FixedRate => "FixedRate"
        case DelayedPeriodic.FixedDelay => "FixedDelay"
    }
}

func ticktockTasksWaitUntil(condition: () -> Bool, timeout: Duration): Unit {
    let deadline = DateTime.now() + timeout
    while (!condition() && DateTime.now() < deadline) {
        sleep(10 * Duration.millisecond)
    }
}

/**
 * `@TicktockTasks` 的最小用法：一个类、一个 `@CronTask` 方法。
 *
 * 宏应做到三件事：把类注册为 bean（否则生成的 `lookup<T>()` 取不到实例）、
 * 在包初始化时把注解方法登记到 `Ticktock`、触发时调用该方法。
 */
@TicktockTasks
public class TicktockTasksSingleSample {
    public let counter = AtomicInt64(0)

    @CronTask[cron: "1 2 3 29 2 *"]
    public func ticktockTasksOnCron(): Unit {
        counter.fetchAdd(1)
    }
}

/** 同一个类里两个 `@CronTask` 方法：两个都应各自登记，互不覆盖。 */
@TicktockTasks
public class TicktockTasksTwoCronSample {
    public let firstCounter = AtomicInt64(0)
    public let secondCounter = AtomicInt64(0)

    @CronTask[cron: "1 2 3 29 2 *"]
    public func ticktockTasksFirst(): Unit {
        firstCounter.fetchAdd(1)
    }

    @CronTask[cron: "1 2 3 29 2 *"]
    public func ticktockTasksSecond(): Unit {
        secondCounter.fetchAdd(1)
    }
}

/** `once: true` 的 cron 任务：触发一次后从时间轮里摘除。 */
@TicktockTasks
public class TicktockTasksOnceSample {
    public let counter = AtomicInt64(0)

    @CronTask[cron: "5 6 7 29 2 *", once: true]
    public func ticktockTasksOnCronOnce(): Unit {
        counter.fetchAdd(1)
    }
}

/** 同一个类里既有 `@CronTask` 又有 `@DelayedTask`：两条登记路径共用一张方法表。 */
@TicktockTasks
public class TicktockTasksMixedSample {
    public let cronCounter = AtomicInt64(0)
    public let delayedCounter = AtomicInt64(0)

    @CronTask[cron: "1 2 3 29 2 *"]
    public func ticktockTasksMixedCron(): Unit {
        cronCounter.fetchAdd(1)
    }

    @DelayedTask[immediate: true, delay: Duration.second]
    public func ticktockTasksMixedDelayed(): Unit {
        delayedCounter.fetchAdd(1)
    }
}

/** `@DelayedTask[immediate: true]`：登记时立刻执行一次（走 addOrReplaceDelayTask 的立即分支）。 */
@TicktockTasks
public class TicktockTasksImmediateDelayedSample {
    public let counter = AtomicInt64(0)

    @DelayedTask[immediate: true, delay: Duration.second]
    public func ticktockTasksOnImmediate(): Unit {
        counter.fetchAdd(1)
    }
}

/** `extract` 的样本：注解只应命中"无参实例方法"，带参与未注解的方法都要排除。 */
public class TicktockTasksExtractSample {
    @CronTask[cron: "1 2 3 29 2 *", once: true, concurrentable: true]
    public func ticktockTasksAnnotated(): Unit {}

    @CronTask[cron: "0/5 * * * * *"]
    public func ticktockTasksAnnotatedWithParam(ignored: Int64): Unit {}

    public func ticktockTasksPlain(): Unit {}
}

/** `DelayedTicktockTaskImpl.extract` 的样本。delay 只能是编译期常量（std 的 Duration 常量）。 */
public class TicktockTasksDelayedExtractSample {
    @DelayedTask[delayedPeriodic: DelayedPeriodic.FixedRate, immediate: true, delay: Duration.second]
    public func ticktockTasksDelayed(): Unit {}
}

@Test
public class TicktockTasksMacro_test {
    @TestCase
    public func testMacroRegistersCronTaskAndFiresIt(): Unit {
        // 宏注入的 @Bean 让类可被 lookup 取到（生成代码正是通过它调用目标方法）
        @Assert(lookupOption<TicktockTasksSingleSample>().isSome(), true)
        let sample = lookup<TicktockTasksSingleSample>()
        let before = sample.counter.load()
        Ticktock.instance.emit(TICKTOCK_TASKS_TIME)
        ticktockTasksWaitUntil({=> sample.counter.load() > before}, 5 * Duration.second)
        @Assert(sample.counter.load() - before, 1)
        // 非 once 任务：同一时刻再次 tick 还会再执行一次
        Ticktock.instance.emit(TICKTOCK_TASKS_TIME)
        ticktockTasksWaitUntil({=> sample.counter.load() - before == 2}, 5 * Duration.second)
        @Assert(sample.counter.load() - before, 2)
    }

    @TestCase
    public func testTwoCronTasksInOneClassBothFire(): Unit {
        let sample = lookup<TicktockTasksTwoCronSample>()
        let firstBefore = sample.firstCounter.load()
        let secondBefore = sample.secondCounter.load()
        Ticktock.instance.emit(TICKTOCK_TASKS_TIME)
        ticktockTasksWaitUntil(
            {=> sample.firstCounter.load() > firstBefore && sample.secondCounter.load() > secondBefore},
            3 * Duration.second)
        @Assert(sample.firstCounter.load() - firstBefore, 1)
        @Assert(sample.secondCounter.load() - secondBefore, 1)
    }

    @TestCase
    public func testOnceCronTaskRunsOnlyOnce(): Unit {
        let sample = lookup<TicktockTasksOnceSample>()
        let before = sample.counter.load()
        Ticktock.instance.emit(TICKTOCK_TASKS_ONCE_TIME)
        ticktockTasksWaitUntil({=> sample.counter.load() > before}, 5 * Duration.second)
        @Assert(sample.counter.load() - before, 1)
        // once 任务执行后已被摘除：同一时刻再 tick 不会执行
        Ticktock.instance.emit(TICKTOCK_TASKS_ONCE_TIME)
        sleep(500 * Duration.millisecond)
        @Assert(sample.counter.load() - before, 1)
    }

    @TestCase
    public func testCronAndDelayedTasksInOneClass(): Unit {
        let sample = lookup<TicktockTasksMixedSample>()
        let cronBefore = sample.cronCounter.load()
        Ticktock.instance.emit(TICKTOCK_TASKS_TIME)
        ticktockTasksWaitUntil(
            {=> sample.cronCounter.load() > cronBefore && sample.delayedCounter.load() >= 1}, 5 * Duration.second)
        @Assert(sample.cronCounter.load() - cronBefore, 1)
        @Assert(sample.delayedCounter.load() >= 1, true)
    }

    @TestCase
    public func testImmediateDelayedTaskRunsOnRegistration(): Unit {
        let sample = lookup<TicktockTasksImmediateDelayedSample>()
        ticktockTasksWaitUntil({=> sample.counter.load() >= 1}, 5 * Duration.second)
        @Assert(sample.counter.load() >= 1, true)
    }
}

@Test
public class TicktockTasksExtract_test {
    @TestCase
    public func testCronExtractKeepsOnlyAnnotatedNoParamFunctions(): Unit {
        let found = CronTicktockTaskImpl.extract<TicktockTasksExtractSample>()
        @Assert(found.size, 1)
        let (annotation, functionName) = found[0]
        @Assert(functionName, "ticktockTasksAnnotated")
        @Assert(annotation.cron, TICKTOCK_TASKS_CRON)
        @Assert(annotation.once, true)
        @Assert(annotation.concurrentable, true)
    }

    @TestCase
    public func testCronExtractReturnsEmptyForClassWithoutCronTask(): Unit {
        @Assert(CronTicktockTaskImpl.extract<TicktockTasksDelayedExtractSample>().size, 0)
    }

    @TestCase
    public func testDelayedExtractKeepsAnnotationFields(): Unit {
        let found = DelayedTicktockTaskImpl.extract<TicktockTasksDelayedExtractSample>()
        @Assert(found.size, 1)
        let (annotation, functionName) = found[0]
        @Assert(functionName, "ticktockTasksDelayed")
        @Assert(annotation.delay, Duration.second)
        @Assert(annotation.immediate, true)
        @Assert(ticktockTasksPeriodicName(annotation.delayedPeriodic), "FixedRate")
    }

    @TestCase
    public func testDelayedExtractReturnsEmptyForClassWithoutDelayedTask(): Unit {
        @Assert(DelayedTicktockTaskImpl.extract<TicktockTasksExtractSample>().size, 0)
    }
}

@Test
public class TicktockTaskImpl_test {
    @TestCase
    public func testCronImplCarriesAnnotationFieldsAndRunsCallee(): Unit {
        let calls = AtomicInt64(0)
        func callee(): Unit {
            calls.fetchAdd(1)
        }
        let impl = CronTicktockTaskImpl(
            "TicktockTaskImpl_test#cron", CronTask(cron: TICKTOCK_TASKS_CRON, once: true, concurrentable: true), callee)
        @Assert(impl.name, "TicktockTaskImpl_test#cron")
        @Assert(impl.cron, TICKTOCK_TASKS_CRON)
        @Assert(impl.once, true)
        @Assert(impl.concurrentable, true)
        impl.execute()
        @Assert(calls.load(), 1)
    }

    @TestCase
    public func testDelayedImplCarriesAnnotationFieldsAndRunsCallee(): Unit {
        let calls = AtomicInt64(0)
        func callee(): Unit {
            calls.fetchAdd(1)
        }
        let impl = DelayedTicktockTaskImpl(
            "TicktockTaskImpl_test#delayed",
            DelayedTask(delayedPeriodic: DelayedPeriodic.FixedDelay, immediate: false, delay: Duration.second),
            callee)
        @Assert(impl.name, "TicktockTaskImpl_test#delayed")
        @Assert(impl.delay, Duration.second)
        @Assert(impl.immediate, false)
        @Assert(ticktockTasksPeriodicName(impl.delayedPeriodic), "FixedDelay")
        // delay 任务以"now + delay"生成的 7 段表达式登记：秒 分 时 日 月 星期 年
        @Assert(impl.cron.split(" ").size, 7)
        impl.execute()
        @Assert(calls.load(), 1)
    }
}

/*
   Copyright (c) [2022] [WuJingrun（吴京润）]
   fountain is licensed under Mulan PSL v2.
   You can use this software according to the terms and conditions of the Mulan PSL v2.
   You may obtain a copy of Mulan PSL v2 at:
           http://license.coscl.org.cn/MulanPSL2
   THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
   See the Mulan PSL v2 for more details.
 */

package f_ticktock

import std.collection.concurrent.ConcurrentHashMap
import std.collection.Map
import std.collection.HashMap
import std.collection.Set
import std.process.Process
import std.sync.*
public import std.time.DateTime

import f_exception.IllegalStateException
import f_log.LoggerFactory
import f_ticktock.exception.TicktockException

/**
 * 时间轮单位初始化顺序任意，TicktockTaskExecutor必须先初始化；所有时间轮单位都初始化完成才能launch()
 * 执行launch以前或以后都可以随时增删任务
 * create*Wheel(Currently)是为了方便单元测试的，实际使用默认就够了
 * 本类对象能接收的cron表达式，简单说明如下：
 * 多个表达式可以用|分隔
 * 包含用空格分隔的六部分，从左至右依次是秒 分 时 日 月 星期
 * 每一部分可以用*表示每时间单位
 * 每一部分可以用m/n表示在上级时间单位的一个周期内，从当前时间单位的第m单位开始每n个单位触发一次，n是0的，抛出异常
 * 每一部分可以用英文逗号分隔表示当前时间单位可以有多个值
 * 每一部分可以用-分隔表示范围取值，eg. 1-7表示取值是从1到7，m-n必须满足m<n，1,3,4-8,11，表示取值是 1 3 4 5 6 7 8 11
 *
 * - 可以结合使用，0/5-30表示取值范围是0 5 10 15 20 25 30
 * 星号和/一起使用时，*会替换为当前时间单位的最小值
 * 大写L可以在任意时间单位，表示它所占时间单位的最大值
 *
 * 秒 分 时的取值范围是[0,59]
 *
 * 日的取值范围是[1,31]，对于不足31天的月份，程序会自动处理，当月没有那一天的任务会被跳过，大写L表示指定月份的最后一天
 * 0/2 的取值范围分别是2 4 6 8 10 12 14 16 18 20 22 24 26 28 30
 * 月的取值范围是[1,12]，0/2的取值范围是2 4 6 8 10 12
 *
 * 星期的取值范围是[0,7]，如果星期单取0，会自动转换为7；
 * 对于取值包含符号-的，如果取值是0-7，会转换为1-7，如果取值是0-n，1 <= n < 7，会转换为1-n,7
 * 对于包含符号/的，如果取值是0/n，1<= n <=7，会转换为n/n,7
 * 对于星期，这么考虑0的目的是为了有些人会把星期日当作一周的第一天，星期日是0；有些人会把星期日当作一周的最后一天，星期日是7
 * 本时间轮实现把星期日当作一周的最后一天，所以做以上转换
 *
 * eg. 0/5-30 0-5 1/2 L * 1
 * 上面的表达式意思是每月最后一天如果刚好是周一就从1点整开始每两小时，0到5分钟内，0到30秒内每5秒执行一次
 */
public class Ticktock <: Emitter {
    private static let LOGGER = LoggerFactory.getLogger("commons/timewheel.TicktockLauncheer")

    /**
     * 此处不与TikTok共用线程池目的是防止多线程同时操作时间轮，
     * 虽然几乎不可能发生，还是为了以防万一，万一发生了，按这个线程池的初始化参数，会立即抛出异常。
     * 执行任务的线程池是另外一个。
     */
    private let tasks = ConcurrentHashMap<String, (TicktockTask, Collection<CronDataCollection>)>()
    private let ticktock = Chrono()
    public init() {
        Process.current.atExit(shutdown)
    }

    public func launch(){
        ticktock.start(this)
    }

    public func removeTask(task: TicktockTask) {
        removeTask(task.name)
    }

    public func removeTask(name: String): Unit {
        tasks.remove(name)
    }

    public func addOrReplaceDelayTask(
        name: String,
        delayedPeriodic: DelayedPeriodic,
        delay: Duration,
        immediate: Bool,
        function: () -> Unit
    ) {
        addOrReplaceDelayTask(DelayedCronTicktockTask(name, delayedPeriodic, delay, immediate, function))
    }
    public func addOrReplaceDelayTask(task: DelayedCronTicktockTaskDef) {
        addOrReplaceDelayTask(DelayedCronTicktockTask(task))
    }
    public func addOrReplaceDelayTask(task: DelayedCronTicktockTask) {
        task.wrapExecutor(removeTask, addOrReplaceDelayTask0)
        addOrReplaceDelayTask0(task)
    }
    private func addOrReplaceDelayTask0(task: DelayedCronTicktockTask): Unit {
        if (task.immediate) {
            spawn {
                task.execute()
            }
            if (task.once) {
                return
            }
        }
        addOrReplaceTask(task, task.cron)
    }

    public func addOrReplaceTask(task: CronTicktockTask) {
        addOrReplaceTask(task, task.cron)
    }
    public func addOrReplaceTask(
        taskName!: String,
        taskCron!: String,
        execOnce!: Bool = false,
        concurrenctly!: Bool = false,
        executor!: () -> Unit,
        isExecuting!: (Int64) -> Bool = {stamp => DefaultTicktockTaskExecuting.executing(taskName, stamp)},
        toReset!: (Int64) -> Unit = {stamp => DefaultTicktockTaskExecuting.reset(taskName, stamp)}
    ) {
        addOrReplaceTask(
            FuncCronTicktockTask(
                taskName: taskName,
                taskCron: taskCron,
                execOnce: execOnce,
                concurrenctly: concurrenctly,
                executor: executor,
                isExecuting: isExecuting,
                toReset: toReset
            )
        )
    }

    /**
     * 添加任务
     * @param task
     * @param cronExpr 关于表达式的解释请见{@code CronCompiler}
     */
    public func addOrReplaceTask(task: TicktockTask, cronExpr: String) {
        tasks.put(task.name, (task, CronCompiler.compile(cronExpr)))
    }

    public func emit(now: DateTime): Unit {
        for ((name, (task, crons)) in tasks) {
            spawn {
                var emitted = false
                var once = false
                try {
                    for(cron in crons where cron.matches(now)){
                        task.execute()
                        once = task.once
                        if(once){
                            this.removeTask(task)
                        }
                        emitted = true
                        break
                    }
                    if (LOGGER.debugEnabled) {
                        LOGGER.debug(
                            "Ticktock.emit:${name}; ${emitted}; ${once}"
                        )
                    }
                } catch (e: Exception) {
                    LOGGER.warn(
                        "Ticktock.emit:${name}; ${emitted}; ${once}",
                        e
                    )
                }
            }
        }
    }

    public func shutdown() {
        ticktock.shutdown()
    }
}

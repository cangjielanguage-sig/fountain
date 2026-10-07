# CRON timer
`fountain::f_ticktock` is a CRON timer
---

## Creating a timer task

```cj
import fountain::f_ticktock.*
import fountain::f_bean.*
import fountain::f_bean.macros.*

@Bean
public class TickTockTask <: CronTicktockTask {
    public prop cron: String {
        get() {
            '1/3-45 * * * * * *'//The trailing * of a CRON expression may be omitted, i.e. this expression can be shortened to 1/3-45
        }
    }
    public func execute(): Unit {
        ...//Timer task logic
    }
    /**
     * Whether the task runs only once; override this method for tasks that must run only once
     *
     * @return true means run only once, false means run many times. This function may be left unimplemented; the default is false
     */
    public prop once: Bool {
        get() {
            return false
        }
    }
    /**
     * Whether the task may run concurrently
     *
     * @return true means concurrent execution is allowed, false means it is not. Concurrent execution means the state of the
     * previous run does not affect whether the task runs when the next period arrives. This function may be left unimplemented; the default is false
     */
    public prop concurrentable: Bool {
        get() {
            return false
        }
    }
    /**
     * Whether the current task is running. It may be left unimplemented; the default keeps accounts by
     * "task name + timestamp"; developers may override this method with their own check
     */
    public func executing(stamp: Int64): Bool
    /**
     * Reset the execution state. It may be left unimplemented; the default resets the account kept by
     * "task name + timestamp"; developers may override this method with their own logic
     */
    public func reset(stamp: Int64): Unit
    /**
     * Task name. By default it is the fully qualified name of the timer task implementation type
     */
    public public open prop name: String {
        get() {
            ClassTypeInfo.of(this).qualifiedName
        }
    }
    public func toString(): String {
        return this.name
    }
}
```

### CRON expression
Every time unit supports the same syntax; from left to right they are: second (SECONDLY), minute (MINUTELY), hour (HOURLY), day (MONTH_DAILY), month (MONTHLY), week (WEEK_DAILY), year (YEARLY)
- `*` means any value
- `start-end` means a range within the current time unit; start is the beginning value of the current time unit in the CRON expression and end is the ending value; the range is inclusive at both ends
- `start/step` start is the beginning value of the current time unit in the CRON expression, end denotes the interval starting from the beginning value
- `start/step-end` start is the beginning value of the current time unit in the CRON expression, step is the interval starting from the beginning value, and end is the ending value; the range is inclusive at both ends
- `,` is a list of several values or several forms of expression within the current time unit
  - `1,3,4,6,9` means any one value; the current time satisfies the condition in the current time unit as long as it equals one of them
  - `1,3,5-10,12/3,15/2-45`, several forms of expression may be separated by `,`; the current time satisfies the condition in the current time unit as long as it matches any one expression
- `L` means the last value of the current time unit in the CRON expression; note that this is the last value, not the maximum. For MONTH_DAILY, the last day of a month differs from month to month because months have different numbers of days.
- Several expressions may be separated by `,` within the same time unit
- `*/`, `*`, `*/*`, `*-*`, `*/*-*`, `*/1-*`, `*/1`, `min/*`, `min/*-*`, `min-*`, `min/1`, `min/1-*`, `*/*-max`, `*/1-max`, `*-max`, `min/*-max`, `min/1-max`, `min-max`
   - These forms are all the same, meaning every value from the minimum to the maximum of the current time unit
- The trailing `*` of a CRON expression may be omitted

### Delayed tasks
A delayed task is a task that runs after a delay once it is registered with the timer.
```cj
public abstract class DelayedTicktockTask <: CronTicktockTask {
    /**
     * Execution mode of a delayed task
     * DelayedPeriodic is an enum with two values:
     *   - FixedRate fixed execution rate: the interval between the start times of consecutive runs is constant, regardless of whether the previous run finished
     *   - FixedDelay fixed execution interval: the interval between two adjacent runs is constant and they never overlap; the next run starts a given time after the previous one ends
     */
    public prop delayedPeriodic: DelayedPeriodic 
    /**
     * Whether the task runs immediately when it is registered with the timer
     */
    public prop immediate: Bool 
    /**
     * Delay before execution
     */
    public prop delay: Duration 
    /**
     * Timer task logic
     */
    public func execute(): Unit 
}
```

## Public API overview

| Type | Description |
|---|---|
| `TicktockTaskDef` / `TicktockTask` / `CronTicktockTask` / `DelayedTicktockTask` | Task contracts and three task base classes |
| `FuncCronTicktockTask` / `FuncInvocationTask` / `FuncInvocationCronTask` | Tasks expressed with functions/closures |
| `DelayedPeriodic` | Execution mode of delayed tasks (`FixedRate` fixed rate / `FixedDelay` fixed delay) |
| `TicktockUnit` and `SecondlyTicktockUnit`, `MinutelyTicktockUnit`, `HourlyTicktockUnit`, `MonthDailyTicktockUnit`, `MonthlyTicktockUnit`, `WeekDailyTicktockUnit`, `YearlyTicktockUnit` | Parsing units for the CRON time units |
| `CronCompiler` / `CronData` / `CronDataCollection` | Compilation of CRON expressions and their data carriers |
| `Ticktock` | The timer itself, driving task execution |
| `TicktockInitializer` | Initializer registered with `f_app` at application startup |
| `TicktockException` | Module exception |

Conventions: when `concurrentable` is `false` (the default), the run is skipped if the previous one has not finished; a task with `once` set to `true` runs only once; `executing`/`reset` keep accounts by "task name + timestamp" by default and can be overridden.

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
package fountain::f_pool.diagnostics

import std.env.{atExit, exit, getStdErr}
import std.sync.{AtomicBool, AtomicInt64}
import fountain::f_base.{registerSignalHandler, resetSignalHandler, Signal, SIGIOT, SIGSEGV}

/**
 * f_pool 的运行时统计 + 致命信号取证（见 .autocode/bugs/bug-archived-on-20261004.md 7.12）。
 *
 * 放在独立的子包 `fountain::f_pool.diagnostics` 里，是为了让最底层的
 * `fountain::f_pool.base.collection`（`SyncDeque`/`LinkedNode`）也能记账/告警，
 * 又不至于形成 `base.collection ⇄ f_pool` 的包环。
 *
 * **输出通道**（一律 **stderr + flush**，不写 stdout —— 库不占应用的数据通道，
 * 且 stdout 重定向时是块缓冲，进程被信号带走会丢掉缓冲区里的行）：
 * - **常规（非崩溃）告警经可注入钩子输出**：默认写 stderr；上层（`KeyPool` 首次建池时自动接，
 *   或应用自己更早调用 `redirectWarningsTo`）可以把它接到 f_log，从而与业务日志同一条流水。
 *   用钩子而不是直接 `import f_log`：本包要保持零依赖，且"往哪写"的决策属于上层；
 * - `dump()` 与信号处理器里那行**固定直写 stderr、不经钩子**：它们可能在崩溃现场执行，
 *   此时日志框架（`AsyncLogger` 是"队列 + 独立写线程"）可能死锁或丢行，不能碰。
 */

/**
 * 要取证的致命信号：`std.runtime.Signal` 只枚举了 SIGTERM/SIGINT 等少数几个，
 * 段错误/异常终止用 f_base 里自定的信号号（`SIGSEGV` / `SIGIOT`）构造。
 */
@When[os != "Windows"]
private let FATAL_SIGNALS = [Signal(SIGSEGV, 'segv'), Signal(SIGIOT, 'abort')]

/**
 * f_pool 的运行时统计 + 致命信号取证（见 .autocode/bugs/bug-archived-on-20261004.md 7.12）。
 *
 * 放在独立的子包 `fountain::f_pool.diagnostics` 里，是为了让最底层的
 * `fountain::f_pool.base.collection`（`SyncDeque`/`LinkedNode`）也能记账，
 * 又不至于形成 `base.collection ⇄ f_pool` 的包环。
 *
 * 两件事：
 * 1. **自愈动作计数**：滞留项救回、记账校正、回调抛异常、后台维护线程重启…都记数。
 *    即使问题不复现，也能从计数判断"到底发生过没有"，而不是只能靠肉眼翻日志；
 * 2. **致命信号取证**：进程因 SIGSEGV / SIGABRT 挂掉前，先把上面这些计数与池的总体情况打出来。
 *    7.12 那次 SIGSEGV 只出现过一次、没留栈没留日志 —— 这个机制是为"下一次"准备的。
 *
 * 注意：信号处理器里只做最保守的事（打印一行 → 复位信号 → `exit(134)`），且会**覆盖**应用为这两个信号
 * 注册的处理器；不想被覆盖就把 `CRASH_DUMP_ON_FATAL` 置 false，或在应用启动早期调用 `uninstallCrashHandler()`。
 */
public struct PoolDiagnostics {
    /** 首次建池时是否自动安装致命信号处理器。 */
    public static const CRASH_DUMP_ON_FATAL = true

    private static let installed = AtomicBool(false)
    private static let dumping = AtomicBool(false)

    private static let createdPools = AtomicInt64(0)
    private static let closedPools = AtomicInt64(0)
    private static let addedItems = AtomicInt64(0)
    private static let borrowedItems = AtomicInt64(0)
    private static let returnedItems = AtomicInt64(0)
    private static let destroyedItems = AtomicInt64(0)
    /** checker / destroier / creator 回调抛异常的次数。 */
    private static let callbackErrors = AtomicInt64(0)
    /** 滞留在非 idle 状态的池项被救回的数量（见 7.2）。 */
    private static let strandedRevived = AtomicInt64(0)
    /** 队列计数脱钩被校正的次数（见 7.2）。 */
    private static let bookkeepingHealed = AtomicInt64(0)
    /** 后台维护线程异常退出后被看护重开的次数（见 7.12）。 */
    private static let scheduleRestarts = AtomicInt64(0)
    /** 已完成的巡检审计轮数。 */
    private static let auditRounds = AtomicInt64(0)

    // === 记账钩子：module 级可见（`protected`），供 f_pool 内部的各层调用 ===
    protected static func onPoolCreated(): Unit {
        createdPools.fetchAdd(1)
    }
    protected static func onPoolClosed(): Unit {
        closedPools.fetchAdd(1)
    }
    protected static func onItemAdded(): Unit {
        addedItems.fetchAdd(1)
    }
    protected static func onItemBorrowed(): Unit {
        borrowedItems.fetchAdd(1)
    }
    protected static func onItemReturned(): Unit {
        returnedItems.fetchAdd(1)
    }
    protected static func onItemDestroyed(): Unit {
        destroyedItems.fetchAdd(1)
    }
    protected static func onCallbackError(): Unit {
        callbackErrors.fetchAdd(1)
    }
    protected static func onStrandedRevived(count: Int64): Unit {
        strandedRevived.fetchAdd(count)
    }
    protected static func onBookkeepingHealed(): Unit {
        bookkeepingHealed.fetchAdd(1)
    }
    protected static func onScheduleRestart(): Unit {
        scheduleRestarts.fetchAdd(1)
    }
    protected static func onAuditRound(): Unit {
        auditRounds.fetchAdd(1)
    }

    /**
     * 诊断/告警的唯一落点：**stderr + 立刻 flush**。
     * 不用 stdout：库不该占应用的数据通道，而且实测 stdout 在重定向时是块缓冲，
     * 进程被信号带走会丢掉缓冲区里的行 —— 而告警往往正是"崩溃前的最后一条"。
     */
    private static func writeDiagnostic(line: String): Unit {
        let err = getStdErr()
        err.writeln(line)
        err.flush()
    }

    /** 常规告警的输出钩子（默认写 stderr）。 */
    protected static var warnHook: (String) -> Unit = {message => writeDiagnostic(message)}
    /** 严重告警的输出钩子（默认写 stderr）。 */
    protected static var errorHook: (String) -> Unit = {message => writeDiagnostic(message)}
    private static let hooksInstalled = AtomicBool(false)

    /**
     * 接管本模块的告警输出（幂等；应用可以在启动早期调用它把告警接进自己的 logger/采集器，
     * 之后 `KeyPool` 首次建池时的默认接线不会再覆盖它）。
     */
    public static func redirectWarningsTo(warn!: (String) -> Unit, error!: (String) -> Unit): Unit {
        warnHook = warn
        errorHook = error
        hooksInstalled.store(true)
    }

    /** 首次建池时接一次默认输出；应用已经用 `redirectWarningsTo` 接管过就不动。 */
    protected static func installDefaultHooks(warn: (String) -> Unit, error: (String) -> Unit): Unit {
        if (!hooksInstalled.compareAndSwap(false, true)) {
            return
        }
        warnHook = warn
        errorHook = error
    }

    /** 常规告警（默认写 stderr，可被 `redirectWarningsTo` 接管）。 */
    protected static func warn(message: String): Unit {
        warnHook(message)
    }
    /** 不变式被破坏等严重情况（同 `warn` 的通道）。 */
    protected static func error(message: String): Unit {
        errorHook(message)
    }

    /** 异常计数之和（回调异常 + 滞留救回 + 记账校正 + 线程重开）：用作"是否有异常发生"的签名。 */
    private static func anomalySignature(): Int64 {
        callbackErrors.load() + strandedRevived.load() + bookkeepingHealed.load() + scheduleRestarts.load()
    }
    private static let lastReportedSignature = AtomicInt64(-1)
    private static let shutdownReportInstalled = AtomicBool(false)

    /**
     * 计数自上次报告以来有变化就落一条统计（走告警通道：默认写 stderr，被 `KeyPool` 接到 f_log）。
     * 这是致命崩溃取证**实际可用**的那一半：崩溃前日志里已经有"最后已知状态"，
     * 不需要（也拿不到）SIGSEGV 现场。返回本次是否输出了统计。
     */
    protected static func reportIfChanged(reason: String): Bool {
        let current = anomalySignature()
        if (current == lastReportedSignature.load()) {
            return false
        }
        lastReportedSignature.store(current)
        warn("[FOUNTAIN_POOL.diag] ${reason}: ${snapshot()}")
        true
    }

    /** 注册"进程退出时若有异常就落一次统计"（幂等；`KeyPool` 首次建池时调用）。健康时静默。 */
    protected static func installShutdownReport(): Unit {
        if (!shutdownReportInstalled.compareAndSwap(false, true)) {
            return
        }
        atExit {
            reportIfChanged('shutdown')
            ()
        }
    }

    /** 统计快照（单行，便于直接塞进日志/崩溃输出）。 */
    public static func snapshot(): String {
        'pools=${createdPools.load()}/${closedPools.load()} items=+${addedItems.load()} borrow=${borrowedItems.load()} return=${returnedItems.load()} destroy=${destroyedItems.load()} callbackErr=${callbackErrors.load()} strandedRevived=${strandedRevived.load()} bookkeepingHealed=${bookkeepingHealed.load()} scheduleRestarts=${scheduleRestarts.load()} audits=${auditRounds.load()}'
    }

    /**
     * 输出统计（带固定前缀，便于 grep）。**固定写 stderr、不经告警钩子**：
     * 它和信号处理器共享"崩溃时也必须能出来"的通道，而钩子可能被接到日志框架上（崩溃现场不可信）。
     * 用 stderr 而不是 stdout 是因为实测：stdout 重定向到文件时是块缓冲，进程被信号带走后
     * 缓冲区里的行**不会落盘**（最后一行丢掉），stderr 的不丢。
     */
    public static func dump(reason!: String = 'manual'): Unit {
        writeDiagnostic("[FOUNTAIN_POOL.diag] ${reason}: ${snapshot()}")
    }

    /**
     * 安装致命信号处理器（幂等；首次建池时按 `CRASH_DUMP_ON_FATAL` 自动调用）。
     * 处理器行为：打印一行统计 ⇒ 复位这两个信号（退出过程中再崩就交给系统默认处理，避免递归）⇒ `exit(134)`。
     *
     * ⚠️ **实测限制（2026-10-04）**：在 Cangjie 运行时里 SIGSEGV / SIGABRT 由运行时自己的 fatal handler
     * 先行接管（stderr 打出 `CJNative Handle signal: N` + `Check failed: …` 后 abort），本处理器**不会被调用** ——
     * `registerSignalHandler` 与 `resetAndRegisterSignalHandler` 都实测过，进程依旧以 139 退出，我们这行没打出来。
     * 因此真正管用的是 `reportIfChanged()`（异常发生即落统计）与 `installShutdownReport()`（退出时落统计）；
     * 这个 API 保留给"非 Cangjie 运行时宿主"或"将来运行时放开致命信号"的场景。
     */
    @When[os != "Windows"]
    public static func installCrashHandler(): Unit {
        if (!installed.compareAndSwap(false, true)) {
            return
        }
        registerSignalHandler(FATAL_SIGNALS){ signal =>
            if (dumping.compareAndSwap(false, true)) {
                // stderr + flush：stdout 在重定向时是块缓冲，进程被信号带走会丢掉最后一行（实测）
                writeDiagnostic("[FOUNTAIN_POOL.crash] fatal signal=${signal}, ${snapshot()}")
                resetSignalHandler(FATAL_SIGNALS)
                exit(134)
            }
            false
        }
    }

    /** 摘掉本模块安装的致命信号处理器（应用想自己接管时调用）。 */
    @When[os != "Windows"]
    public static func uninstallCrashHandler(): Unit {
        if (installed.compareAndSwap(true, false)) {
            resetSignalHandler(FATAL_SIGNALS)
        }
    }

    /** Windows 上不介入信号，仅保留同名 API（处理器安装为空实现），保证跨平台调用点一致。 */
    @When[os == "Windows"]
    public static func installCrashHandler(): Unit {}

    @When[os == "Windows"]
    public static func uninstallCrashHandler(): Unit {}
}

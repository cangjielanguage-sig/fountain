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

import std.env.exit
import std.posix.{SIGSEGV, SIGIOT}
import std.sync.{AtomicBool, AtomicInt64}
import fountain::f_base.{registerSignalHandler, resetSignalHandler, Signal}
import fountain::f_log.LoggerFactory

/**
 * 诊断输出通道：
 * - **常规（非崩溃）告警走 f_log**（`warn`/`error`），与业务日志同一条流水，级别/格式/落盘都由日志配置决定；
 * - `dump()` 例外，仍用 `println` —— 它会被**信号处理器**调用（见 `installCrashHandler`），
 *   那里不能碰日志框架：f_log 是"队列 + 独立写线程"（`AsyncLogger`），崩溃时可能死锁，或那行字永远刷不出来。
 */
private let logger = LoggerFactory.getLogger('fountain::f_pool')

/**
 * 要取证的致命信号：`std.runtime.Signal` 只枚举了 SIGTERM/SIGINT 等少数几个，
 * 段错误/异常终止要用 `std.posix` 的信号号自己构造（`SIGIOT` 即 SIGABRT，号相同）。
 */
@When[os != "Windows"]
private let FATAL_SIGNALS = [Signal(SIGSEGV, 'segv'), Signal(SIGIOT, 'abort')]

/**
 * f_pool 的运行时统计 + 致命信号取证（见 bug.md 7.12）。
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

    /** 常规告警（走 f_log）。 */
    protected static func warn(message: String): Unit {
        logger.warn(message)
    }
    /** 不变式被破坏等严重情况（走 f_log）。 */
    protected static func error(message: String): Unit {
        logger.error(message)
    }

    /** 统计快照（单行，便于直接塞进日志/崩溃输出）。 */
    public static func snapshot(): String {
        'pools=${createdPools.load()}/${closedPools.load()} items=+${addedItems.load()} borrow=${borrowedItems.load()} return=${returnedItems.load()} destroy=${destroyedItems.load()} callbackErr=${callbackErrors.load()} strandedRevived=${strandedRevived.load()} bookkeepingHealed=${bookkeepingHealed.load()} scheduleRestarts=${scheduleRestarts.load()} audits=${auditRounds.load()}'
    }

    /**
     * 输出统计（带固定前缀，便于 grep）。走 f_log，跟业务日志同一条流水；
     * 崩溃路径**不经过这里**（`installCrashHandler` 的处理器自己 `println`），所以日志框架不可用时也不受影响。
     */
    public static func dump(reason!: String = 'manual'): Unit {
        logger.warn("[FOUNTAIN_POOL.diag] ${reason}: ${snapshot()}")
    }

    /**
     * 安装致命信号处理器（幂等；首次建池时按 `CRASH_DUMP_ON_FATAL` 自动调用）。
     * 处理器行为：打印一行统计 ⇒ 复位这两个信号（退出过程中再崩就交给系统默认处理，避免递归）⇒ `exit(134)`。
     */
    @When[os != "Windows"]
    public static func installCrashHandler(): Unit {
        if (!installed.compareAndSwap(false, true)) {
            return
        }
        registerSignalHandler(FATAL_SIGNALS){ signal =>
            if (dumping.compareAndSwap(false, true)) {
                println("[FOUNTAIN_POOL.crash] fatal signal=${signal}, ${snapshot()}")
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

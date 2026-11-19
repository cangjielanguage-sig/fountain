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
package fountain::fprobe.tui

import std.sync.Mutex
import fountain::f_base.ExitCallbacks
import fountain::f_probe.ProbeException

/** 退出钩子抽象，便于用假实现触发「信号到达」。 */
public interface ExitHooks {
    func toExitGracefully(): Unit

    func atExit(priority: UInt16, callback: () -> Unit): Unit
}

/** 生产实现：委托 `f_base.ExitCallbacks`，注册 SIGINT/SIGTERM 的优雅退出。 */
public class SystemExitHooks <: ExitHooks {
    public init() {}

    public func toExitGracefully(): Unit {
        ExitCallbacks.toExitGracefully()
    }

    public func atExit(priority: UInt16, callback: () -> Unit): Unit {
        ExitCallbacks.atExit(priority, callback)
    }
}

/** 拉取/渲染等后台组件；`stop` 停线程，`close` 释放连接。 */
public interface SupervisorComponents {
    func start(): Unit

    func stop(): Unit

    func close(): Unit
}

/**
 * 监督端运行时（设计 D9 / 「Concurrency & Lifecycle」）。
 *
 * - `resident=true`：不碰终端，日志是唯一输出；
 * - `resident=false`：先校验 TTY，再启动 painter 与按键循环；
 * - 无论哪种模式，退出钩子都会停止后台组件、关闭连接并恢复终端。
 */
public class SupervisorApp {
    private let painter: Painter
    private let detector: TtyDetector
    private let hooks: ExitHooks
    private let components: SupervisorComponents
    private let log: (String) -> Unit
    private let keySource: ?KeySource

    private let stateLock = Mutex()
    private var runningState = false
    private var tuiActive = false
    private let viewLock = Mutex()
    private var currentView: ViewModel

    public init(painter: Painter, detector: TtyDetector, hooks: ExitHooks,
        components: SupervisorComponents, log!: (String) -> Unit = {line => println(line)},
        keySource!: ?KeySource = None<KeySource>, view!: ViewModel = ViewModel.empty()) {
        this.painter = painter
        this.detector = detector
        this.hooks = hooks
        this.components = components
        this.log = log
        this.keySource = keySource
        this.currentView = view
    }

    /**
     * 启动运行时。
     *
     * 返回 0 表示已进入运行态；非 0 为启动期错误码（与 CLI 约定一致）。
     */
    public func start(resident: Bool): Int64 {
        hooks.toExitGracefully()
        hooks.atExit(0, {=> shutdown()})

        if (!resident) {
            try {
                requireTty(detector)
            } catch (e: ProbeException) {
                log(e.message)
                return 2
            }
            try {
                painter.start()
                synchronized(stateLock) {
                    tuiActive = true
                }
            } catch (e: Exception) {
                log('TUI 初始化失败: ${e.message}')
                return 2
            } catch (e: Error) {
                log('TUI 初始化失败: ${e.message}')
                return 2
            }
        }

        components.start()
        synchronized(stateLock) {
            runningState = true
        }
        log(if (resident) {
            "fprobe supervisor: resident 模式已启动，日志是唯一输出"
        } else {
            "fprobe supervisor: TUI 模式已启动"
        })
        0
    }

    public func running(): Bool {
        synchronized(stateLock) {
            runningState
        }
    }

    /** 可被信号钩子直接调用；重复调用无副作用。 */
    public func shutdown(): Unit {
        let shouldStop = synchronized(stateLock) {
            let wasRunning = runningState
            runningState = false
            wasRunning
        }
        if (!shouldStop) {
            return
        }
        components.stop()
        components.close()
        let needRestore = synchronized(stateLock) {
            let active = tuiActive
            tuiActive = false
            active
        }
        if (needRestore) {
            painter.restore()
        }
        log("fprobe supervisor: 已退出")
    }

    /** 阻塞运行直到 [shutdown]；按键读取在独立线程，主线程只等待运行态结束。 */
    public func run(resident: Bool): Int64 {
        let code = start(resident)
        if (code != 0) {
            return code
        }
        match (keySource) {
            case Some(source) =>
                let keyThread = spawn {=> keyLoop(source)}
                while (running()) {
                    sleep(Duration.millisecond * 50)
                }
                keyThread.get()
            case None =>
                while (running()) {
                    sleep(Duration.millisecond * 200)
                }
        }
        0
    }

    /** 按键线程主体：每次读取有超时，外部 shutdown 后最迟一个超时周期退出。 */
    private func keyLoop(source: KeySource): Unit {
        while (running()) {
            match (source.readKey(100)) {
                case Some(key) =>
                    if (!handle(key)) {
                        return
                    }
                case None => ()
            }
        }
    }

    public func view(): ViewModel {
        synchronized(viewLock) {
            currentView
        }
    }

    private func handle(key: UiKey): Bool {
        match (KeyMap.action(key)) {
            case UiAction.Quit =>
                shutdown()
                false
            case UiAction.Refresh =>
                true
            case UiAction.NextPage =>
                updateView({view => view.nextPage()})
                true
            case UiAction.PreviousPage =>
                updateView({view => view.previousPage()})
                true
            case UiAction.SelectPrevious =>
                updateView({view => view.selectPrevious()})
                true
            case UiAction.SelectNext =>
                updateView({view => view.selectNext()})
                true
            case UiAction.ShowAlarms =>
                updateView({view => view.showAlarms()})
                true
            case UiAction.Ignore =>
                true
        }
    }

    private func updateView(transform: (ViewModel) -> ViewModel): Unit {
        synchronized(viewLock) {
            currentView = transform(currentView)
        }
    }
}

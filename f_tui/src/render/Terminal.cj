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
package fountain::f_tui.render

import fountain::f_tui.{TuiErrorCode, TuiException}
import fountain::f_tui.ansi.AnsiRenderer
import fountain::f_tui.term.*
import std.collection.ArrayList
import std.env.atExit
import std.runtime.{Signal, registerSignalHandler}

/// 进程退出回调的注册表；正常退出、异常退出与信号共用同一组回调。
let F_TUI_EXIT_CALLBACKS: ArrayList<() -> Unit> = ArrayList<() -> Unit>()

func fTuiDispatchExit(): Unit {
    for (callback in F_TUI_EXIT_CALLBACKS) {
        callback()
    }
}

func fTuiSignalHandler(signal: Int32): Bool {
    fTuiDispatchExit()
    false
}

/// 退出钩子抽象；测试注入记录型实现模拟正常/异常/信号三条路径。
public interface ExitHook {
    /// 注册一个退出时执行的回调。
    func register(action: () -> Unit): Unit
}

@When[os != "Windows"]
/// 生产实现：`atExit` + `SIGINT` / `SIGTERM`。
public class SystemExitHook <: ExitHook {
    private static var installed: Bool = false

    public init() {}

    public func register(action: () -> Unit): Unit {
        F_TUI_EXIT_CALLBACKS.add(action)
        if (!installed) {
            installed = true
            atExit(fTuiDispatchExit)
            registerSignalHandler(Signal.SIGINT, fTuiSignalHandler)
            registerSignalHandler(Signal.SIGTERM, fTuiSignalHandler)
        }
    }
}

@When[os == "Windows"]
/// 非 Unix 平台只注册 `atExit`。
public class SystemExitHook <: ExitHook {
    private static var installed: Bool = false

    public init() {}

    public func register(action: () -> Unit): Unit {
        F_TUI_EXIT_CALLBACKS.add(action)
        if (!installed) {
            installed = true
            atExit(fTuiDispatchExit)
        }
    }
}

/// 终端生命周期：TTY 检查 → raw mode → 备用屏 → 隐藏光标。
///
/// 任一步失败按逆序回滚；`restore()` 幂等，并挂在退出钩子上覆盖
/// 正常返回、异常抛出与 `SIGINT` / `SIGTERM`。
public class Terminal {
    private let ffi: PosixFfi
    private let rawMode: RawMode
    private let renderer: AnsiRenderer
    private let bufferRendererValue: BufferRenderer
    private let exitHook: ExitHook
    private let fdIn: Int32
    private let fdOut: Int32
    private var initialized: Bool = false
    private var hookRegistered: Bool = false

    public init(ffi: PosixFfi, writer: TerminalWriter, sizeProvider: SizeProvider,
        exitHook!: ExitHook = SystemExitHook(), fdIn!: Int32 = STDIN_FILENO,
        fdOut!: Int32 = STDOUT_FILENO) {
        this.ffi = ffi
        this.rawMode = RawMode(ffi, fdIn)
        this.renderer = AnsiRenderer(writer)
        this.bufferRendererValue = BufferRenderer(renderer, sizeProvider)
        this.exitHook = exitHook
        this.fdIn = fdIn
        this.fdOut = fdOut
    }

    /// 初始化终端；重复调用是空操作。
    public func start(): Unit {
        if (initialized) {
            return
        }
        if (!ffi.isTty(fdIn) || !ffi.isTty(fdOut)) {
            throw TuiException(TuiErrorCode.Unsupported, "standard input/output is not a tty")
        }
        rawMode.enter()
        if (!renderer.enterAltScreen()) {
            rawMode.restore()
            throw TuiException(TuiErrorCode.Init, "cannot enter alternate screen")
        }
        if (!renderer.hideCursor()) {
            renderer.exitAltScreen()
            rawMode.restore()
            throw TuiException(TuiErrorCode.Init, "cannot hide cursor")
        }
        initialized = true
        if (!hookRegistered) {
            hookRegistered = true
            exitHook.register({=> this.restore()})
        }
    }

    /// 恢复正常终端状态；已恢复时直接返回。
    public func restore(): Unit {
        if (!initialized) {
            return
        }
        renderer.reset()
        rawMode.restore()
        initialized = false
    }

    /// 是否处于初始化完成状态。
    public func isInitialized(): Bool {
        initialized
    }

    /// `Buffer` 渲染器，宿主用它提交帧。
    public func bufferRenderer(): BufferRenderer {
        bufferRendererValue
    }

    /// 当前终端尺寸；未知时为 `None`。
    public func size(): Option<TuiSize> {
        let value = bufferRendererValue.size()
        if (value.isUnknown()) {
            None
        } else {
            Some(value)
        }
    }
}

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
package fountain::fprobe.runtime

import fountain::f_tui.render.Terminal
import fountain::f_tui.term.{IoctlSizeProvider, RealPosixFfi, StdoutTerminalWriter}
import fountain::fprobe.config.SupervisorSettings
import fountain::fprobe.tui.{FprobePainter, KeySource, Painter, StdTtyDetector, SupervisorApp, SystemExitHooks,
    TerminalFrameRenderer, systemKeySource}

/**
 * supervisor 进程装配：把 `SupervisorApp`、运行时组件与终端薄层拼好。
 *
 * 终端对象只创建一次，`SupervisorApp` 负责 `start`/`restore`，`RenderLoop`
 * 只负责 `draw`，避免两个实例各自维护 raw mode 状态。
 */
public class SupervisorBootstrap {
    /** 构建但不运行；用例可注入假 painter/假 detector 的入口由此复用。 */
    public static func build(settings: SupervisorSettings, resident: Bool): SupervisorApp {
        settings.apply()
        let painter: Painter = if (resident) {
            NullPainter()
        } else {
            createPainter()
        }
        let holder = AppHolder()
        let runtime = SupervisorRuntime(settings, resident, painter, holder)
        let keySource: ?KeySource = if (resident) {
            None<KeySource>
        } else {
            Some(systemKeySource())
        }
        let app = SupervisorApp(painter, StdTtyDetector(), SystemExitHooks(), runtime,
            log: {message => eprintln(message)}, keySource: keySource)
        holder.app = Some(app)
        app
    }

    /** 阻塞运行到按键或信号触发退出。 */
    public static func run(settings: SupervisorSettings, resident: Bool): Int64 {
        build(settings, resident).run(resident)
    }

    private static func createPainter(): Painter {
        let ffi = RealPosixFfi()
        let terminal = Terminal(ffi, StdoutTerminalWriter(ffi, 1), IoctlSizeProvider(ffi, 1))
        FprobePainter(TerminalFrameRenderer(terminal))
    }
}

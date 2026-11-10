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

import std.sync.AtomicBool
import fountain::fprobe.collect.Clock
import fountain::fprobe.supervisor.NodeStateStore

/**
 * 渲染线程（设计 D9 / spec「线程职责分离」）。
 *
 * 每帧只从 `NodeStateStore` 复制一次引用，随后在锁外构建 RenderPlan 并绘制；
 * 即使 painter 很慢，也不会持有拉取线程需要的锁。
 */
public class RenderLoop {
    private let store: NodeStateStore
    private let viewProvider: () -> ViewModel
    private let history: HistorySource
    private let painter: Painter
    private let intervalMs: Int64
    private let clock: Clock
    private let alarms: () -> Array<String>
    private let onError: (String) -> Unit
    private let running = AtomicBool(true)

    public init(store: NodeStateStore, viewProvider: () -> ViewModel, history: HistorySource,
        painter: Painter, intervalMs: Int64, clock: Clock, alarms: () -> Array<String>,
        onError!: (String) -> Unit = {message => eprintln("fprobe tui: ${message}")}) {
        this.store = store
        this.viewProvider = viewProvider
        this.history = history
        this.painter = painter
        this.intervalMs = intervalMs
        this.clock = clock
        this.alarms = alarms
        this.onError = onError
    }

    /** 常驻渲染循环：直到 [stop]。 */
    public func run(): Unit {
        while (running.load()) {
            renderOnce()
            clock.wait(intervalMs)
        }
    }

    /** 停止循环；当前帧会完成后再退出。 */
    public func stop(): Unit {
        running.store(false)
    }

    /**
     * 绘制一帧。
     *
     * 渲染异常被局部化：记录后继续下一帧，不把异常抛回调用线程。
     */
    public func renderOnce(): Unit {
        try {
            let plan = RenderPlanBuilder.build(viewProvider(), store.all(), history,
                clock.nowMs(), alarms(), viewportHeight: painter.viewportHeight())
            painter.draw(plan)
        } catch (e: Exception) {
            onError('渲染失败: ${e.message}')
        } catch (e: Error) {
            onError('渲染失败: ${e.message}')
        }
    }
}

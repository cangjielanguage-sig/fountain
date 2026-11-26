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

import std.sync.AtomicBool
import fountain::f_app.InitializerCollection
import fountain::f_probe.ProbeRegistry
import fountain::fprobe.collect.{ProbeFactory, ProbeRunner, SystemClock}
import fountain::fprobe.config.AgentSettings
import fountain::fprobe.custom.CustomLoader
import fountain::fprobe.rpc.ProbeRPCImpl
import fountain::fprobe.snapshot.SnapshotStore

/**
 * `fprobe agent` 的进程装配。
 *
 * 职责是「把已经测过的零件接起来」，不重复实现采集逻辑：
 * 1. 注册内置探针 → 加载 `custom` 扩展 → 实例化注册表；
 * 2. 预热一轮并发布首个快照，避免 CPU/磁盘差分从 0 开始；
 * 3. 后台线程按 `probe_intervalMs` 周期采集；
 * 4. 绑定 [ProbeRPCImpl] 后启动 f_app 的初始化链（含 RPC 服务器），主线程等待退出。
 *
 * 装配与启动分离：`prepare` 可被用例直接断言，`serve` 才进入阻塞。
 */
public class AgentRuntime {
    private let settings: AgentSettings
    private let store: SnapshotStore
    private let runner: ProbeRunner
    private let clock = SystemClock()
    private let running = AtomicBool(true)

    /**
     * 生产装配：注册内置探针、加载扩展库并实例化。
     *
     * `loadCustom=false` 供用例跳过动态库加载；此时只装配内置探针。
     */
    public static func prepare(settings: AgentSettings, loadCustom!: Bool = true): AgentRuntime {
        ProbeFactory.registerProduction(settings)
        if (loadCustom) {
            CustomLoader.load(settings.customDir, settings.customFailFast)
        }
        let agents = ProbeFactory.instantiate()
        let store = SnapshotStore()
        let runner = ProbeRunner(agents, store, SystemClock(), node: settings.host, host: settings.host)
        AgentRuntime(settings, store, runner)
    }

    /** 直接注入仓库与运行器，便于用例断言。 */
    public init(settings: AgentSettings, store: SnapshotStore, runner: ProbeRunner) {
        this.settings = settings
        this.store = store
        this.runner = runner
    }

    /** 当前注册的监控项；来自注册表而不是本地缓存。 */
    public func kinds(): Array<String> {
        ProbeRegistry.agents()
    }

    /** 已发布的快照；未开始采集时是空快照。 */
    public func snapshot(): SnapshotStore {
        store
    }

    /**
     * 进入服务：发布首帧、启动采集线程、启动初始化链，然后阻塞到 [stop]。
     *
     * 返回 0 表示正常退出。RPC 服务器自身是阻塞的，因此每个 initializer 的
     * `start()` 都在独立线程里执行。
     */
    public func serve(): Int64 {
        settings.apply()
        ProbeRPCImpl.install(store)
        runner.warmup()
        let first = runner.tick()
        store.replace(first)
        eprintln('fprobe agent: 已注册 ${ProbeRegistry.agents().size} 个监控项，监听 ${settings.host}:${settings.port}，首帧 ${first.agents.size} 项')

        let collector = spawn { =>
            while (running.load()) {
                store.replace(runner.tick())
                clock.wait(settings.intervalMs)
            }
        }

        let providers = InitializerCollection.initialize()
        for (provider in providers) {
            let current = provider
            spawn { =>
                current().start()
            }
        }

        while (running.load()) {
            clock.wait(500)
        }
        collector.get()
        0
    }

    /** 请求停止采集与主循环；可重复调用。 */
    public func stop(): Unit {
        running.store(false)
    }
}

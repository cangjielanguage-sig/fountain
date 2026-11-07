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
package fountain::f_llm.loom

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

import fountain::f_config.Config
import fountain::f_llm.config.LLMConfig

/** 存储不可用的桩：`list` 直接抛，模拟库比应用晚就绪 / 连接断掉 */
class FailingLoomStore <: LoomStore {
    public func save(flow: LoomFlow): Unit {
    }

    public func get(name: String): ?LoomFlow {
        None
    }

    public func list(offset: Int64, limit: Int64): ArrayList<LoomFlow> {
        throw LoomException('loom store unavailable')
    }

    public func remove(name: String): Bool {
        false
    }
}

@Test
class LoomWiringSupervisor_test {
    private static func plannedJson(name: String): String {
        '{"status":"planned","name":${FlowPlan.jsonQuote(name)},"steps":[{"id":"fetch","kind":"jit",'
        + '"input":'
        + FlowPlan.jsonQuote('let fetch_result = "A"')
        + ',"async":"false"}],"edges":[]}'
    }

    @TestCase
    func testWireSeedsCompiledFlowsWhenSwitchOn(): Unit {
        Supervisor.reset()
        LoomServices.reset()
        Config.set<Bool>([(LLMConfig.LLM_SUPERVISOR, true)])
        // 装配会碰演进族存储：指到内存，避免写默认元数据目录污染别的用例
        Config.set<String>([('llm_metaStore', 'memory')])
        try{
            let store = MemoryLoomStore()
            let flow = LoomFlow('daily', description: '汇总日报')
            flow.planJson = plannedJson('daily')
            flow.mark(LoomStatus.COMPILED)
            store.save(flow)

            let _ = LoomWiring.wire({ _, _, _ => plannedJson('daily') }, store: store)

            let supervisor = Supervisor.current().getOrThrow()
            @Expect(supervisor.routes().size, 1)
            @Expect(supervisor.routable().size, 1)
            @Expect(supervisor.eventOf('daily').getOrThrow(), 'sv/daily')
        }finally{
            Config.remove(LLMConfig.LLM_SUPERVISOR)
            Config.remove('llm_metaStore')
            Supervisor.reset()
            LoomServices.reset()
        }
    }

    /** 存储不可用：装配不中断，Supervisor 装得上但路由为空，流程服务照常可用 */
    @TestCase
    func testWireSurvivesUnavailableStore(): Unit {
        Supervisor.reset()
        LoomServices.reset()
        Config.set<Bool>([(LLMConfig.LLM_SUPERVISOR, true)])
        Config.set<String>([('llm_metaStore', 'memory')])
        try{
            let service = LoomWiring.wire({ _, _, _ => plannedJson('daily') },
                store: FailingLoomStore())
            @Expect(service.status('daily'), '')
            @Expect(Supervisor.current().isSome(), true)
            @Expect(Supervisor.current().getOrThrow().routes().size, 0)

            // 直接看启动报告里的失败标记，避免「静默吞掉」
            let result = LoomBootstrap.startup(LoomRegistry(store: FailingLoomStore()))
            @Expect(result.restoreFailed, true)
            @Expect(result.restored, 0)
        }finally{
            Config.remove(LLMConfig.LLM_SUPERVISOR)
            Config.remove('llm_metaStore')
            Supervisor.reset()
            LoomServices.reset()
        }
    }

    @TestCase
    func testWireSkipsSupervisorWhenSwitchOff(): Unit {
        Supervisor.reset()
        LoomServices.reset()
        Config.remove(LLMConfig.LLM_SUPERVISOR)

        let _ = LoomWiring.wire({ _, _, _ => plannedJson('daily') }, store: MemoryLoomStore())
        @Expect(Supervisor.current().isNone(), true)
        LoomServices.reset()
    }

    /** 装配把恢复结果留下来：库不可用时可观测 */
    @TestCase
    func testWireRecordsRestoreFailure(): Unit {
        Supervisor.reset()
        LoomServices.reset()
        Config.set<Bool>([(LLMConfig.LLM_SUPERVISOR, true)])
        Config.set<String>([('llm_metaStore', 'memory')])
        try {
            let _ = LoomWiring.wire({ _, _, _ => '{}' }, store: FailingLoomStore())

            let reload = LoomWiring.lastReload().getOrThrow()
            @Expect(reload.restoreFailed, true)
            @Expect(reload.toString().contains('restoreFailed'), true)
        } finally {
            Config.remove(LLMConfig.LLM_SUPERVISOR)
            Config.remove('llm_metaStore')
            Supervisor.reset()
            LoomServices.reset()
        }
    }

    /** 调用方先装的宿主不能被 wire 抢走 */
    @TestCase
    func testWireKeepsInstalledHost(): Unit {
        Supervisor.reset()
        LoomServices.reset()
        let custom = SpyHost()
        custom.marker = 'mine'
        LoomServices.installHost(custom)
        try {
            let _ = LoomWiring.wire({ _, _, _ => '{}' }, store: MemoryLoomStore())

            let resolved = match (LoomServices.currentHost()) {
                case Some(value) => match (value as SpyHost) {
                    case Some(spy) => spy.marker
                    case None => 'other'
                }
                case None => 'none'
            }
            @Expect(resolved, 'mine')
        } finally {
            Supervisor.reset()
            LoomServices.reset()
        }
    }

    /** wire 把 characterUserId 装进人格作用域 */
    @TestCase
    func testWireInstallsCharacterScope(): Unit {
        Supervisor.reset()
        LoomServices.reset()
        LoomCharacterScope.reset()
        Config.set<String>([('llm_metaStore', 'memory')])
        try {
            let _ = LoomWiring.wire({ _, _, _ => '{}' }, store: MemoryLoomStore(), characterUserId: 9)
            @Expect(LoomCharacterScope.current().getOrThrow(), 9)
        } finally {
            Config.remove('llm_metaStore')
            LoomCharacterScope.reset()
            Supervisor.reset()
            LoomServices.reset()
        }
    }
}

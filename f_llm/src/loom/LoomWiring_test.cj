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

/** 记录 chat 回调收到的模型名 */
class ChatRecorder {
    public var model: String = ''
    public var calls: Int64 = 0
}

@Test
class LoomWiring_test {
    private static func plannedJson(): String {
        '{"status":"planned","name":"daily","steps":[{"id":"fetch","kind":"jit","input":'
        + FlowPlan.jsonQuote('let fetch_result = "A"')
        + ',"async":"false"}],"edges":[]}'
    }

    @TestCase
    func testWireInstallsServiceAndUsesPlannerModel(): Unit {
        let recorder = ChatRecorder()
        let service = LoomWiring.wire({ model, _, _ =>
            recorder.model = model
            recorder.calls++
            plannedJson()
        }, plannerModel: 'chat-pro', store: MemoryLoomStore())

        @Expect(LoomServices.current().isSome(), true)
        let outcome = service.execute(LoomRequest('daily', '抓取并汇总'))
        @Expect(outcome.status, 'pending')
        @Expect(recorder.calls, 1)
        @Expect(recorder.model, 'chat-pro')
        LoomServices.reset()
    }

    @TestCase
    func testWireFallsBackToMemoryStoreForNonSqlContentFamily(): Unit {
        // 默认 llm_memoryStore 是 f_hydra → 内存存储，不碰数据库
        let service = LoomWiring.wire({ _, _, _ => plannedJson() }, store: MemoryLoomStore())
        @Expect(service.status('not-exist'), '')
        LoomServices.reset()
    }

    /** 配了 cron：启动时把技能演进注册成周期任务 */
    @TestCase
    func testWireRegistersEvolutionTaskWhenCronProvided(): Unit {
        let scheduler = ManualScheduler()
        LoomSchedules.install(scheduler)
        try{
            LoomWiring.wire({ _, _, _ => plannedJson() }, store: MemoryLoomStore(),
                evolutionCron: '0 0 3 * * * *', evolutionUserId: 7)
            @Expect(scheduler.crons.get('loom-skill-evolution').getOrThrow(), '0 0 3 * * * *')
            @Expect(scheduler.jobs.contains('loom-skill-evolution'), true)
        }finally{
            LoomSchedules.reset()
            LoomServices.reset()
        }
    }

    /** 没配 cron：不注册任何演进任务 */
    @TestCase
    func testWireSkipsEvolutionWithoutCron(): Unit {
        let scheduler = ManualScheduler()
        LoomSchedules.install(scheduler)
        try{
            LoomWiring.wire({ _, _, _ => plannedJson() }, store: MemoryLoomStore())
            @Expect(scheduler.crons.size, 0)
        }finally{
            LoomSchedules.reset()
            LoomServices.reset()
        }
    }

    @TestCase
    func testDefaultChatRejectsEmptyModel(): Unit {
        let chat = LoomDefaults.chat('')
        var message = ''
        try{
            chat('', '', 'hi')
        }catch(e: Exception){
            message = e.message
        }
        @Expect(message.contains('not configured'), true)
    }
}

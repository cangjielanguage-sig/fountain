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
import fountain::f_egraph.base.*
import fountain::f_llm.config.LLMConfig

/** 计数器：闭包只能捕获不可变引用，计数放对象字段里 */
class CallCounter {
    public var value: Int64 = 0

    public func next(): Int64 {
        value++
        value
    }
}

/** 可切换的模型回答（冒烟用例用来在同一测试里切换「命中」与「无命中」） */
class ReplyBox {
    public var value: String = ''
}

/** 记录模型调用入参的假宿主：只关心 llm 步骤拿到的 input */
class SupervisorRecordingHost <: LoomHost {
    public let inputs: ArrayList<String> = ArrayList<String>()

    public func render(template: String, e: Event): String {
        LoomHostApi.render(template, e)
    }

    public func callTool(name: String, argsJson: String): String {
        'tool:${name}'
    }

    public func callLlm(model: String, system: String, input: String): String {
        inputs.add(input)
        'OK'
    }
}

@Test
class Supervisor_test {
    /** 一条「llm 步骤」的计划：输入取 `{start.output}`，用来验证派发把描述当作事件数据传进去 */
    private static func llmPlanJson(name: String): String {
        '{"status":"planned","name":${FlowPlan.jsonQuote(name)},"steps":[{"id":"ask","kind":"llm",'
        + '"model":"m","system":"S","input":'
        + FlowPlan.jsonQuote('{start.output}')
        + ',"async":"false"}],"edges":[]}'
    }

    /** 造一个已编译流程的 service（registry 为内存实现） */
    private func compiledService(name: String, description: String,
                                 registry!: ?LoomRegistry = None): (LoomService, LoomFlow) {
        let store = match(registry){
            case Some(value) => value
            case None => LoomRegistry()
        }
        let service = LoomService(Planner({ _, _ => llmPlanJson(name) }), store)
        let flow = LoomFlow(name, description: description)
        flow.planJson = llmPlanJson(name)
        flow.mark(LoomStatus.PENDING)
        store.put(flow)
        service.confirmFlow(name)
        (service, store.get(name).getOrThrow())
    }

    @TestCase
    func testEventNameIsUniquePerFlow(): Unit {
        let daily = Supervisor.eventName('daily')
        let weekly = Supervisor.eventName('weekly')
        @Expect(daily, 'sv/daily')
        @Expect(daily == weekly, false)
    }

    @TestCase
    func testRegisterAndList(): Unit {
        let supervisor = Supervisor()
        let _ = supervisor.register('daily', '汇总日报')
        let _ = supervisor.register('weekly', '汇总周报')

        let routes = supervisor.routes()
        @Expect(routes.size, 2)
        @Expect(routes[0].name, 'daily')
        @Expect(routes[0].event, 'sv/daily')
        @Expect(routes[0].description, '汇总日报')
    }

    @TestCase
    func testRegisterTwiceIsIdempotent(): Unit {
        let supervisor = Supervisor()
        let _ = supervisor.register('daily', '汇总日报')
        let _ = supervisor.register('daily', '汇总日报（更新描述）')

        @Expect(supervisor.routes().size, 1)
        @Expect(supervisor.routes()[0].description, '汇总日报（更新描述）')
    }

    @TestCase
    func testUnregisterRemovesRoute(): Unit {
        let supervisor = Supervisor()
        let _ = supervisor.register('daily', '汇总日报')
        let _ = supervisor.register('weekly', '汇总周报')

        @Expect(supervisor.unregister('weekly'), true)
        @Expect(supervisor.routes().size, 1)
        @Expect(supervisor.eventOf('weekly'), None<String>)
        // 删不存在的名字返回 false，不抛错
        @Expect(supervisor.unregister('weekly'), false)
    }

    @TestCase
    func testRoutableOnlyCompiled(): Unit {
        let supervisor = Supervisor()
        let _ = supervisor.register('daily', '汇总日报', status: LoomStatus.COMPILED)
        let _ = supervisor.register('draft', '还没编译', status: LoomStatus.PENDING)

        // 路由表里两条都在（每个流程都注册）
        @Expect(supervisor.routes().size, 2)
        // 选路候选只留可执行的
        let routable = supervisor.routable()
        @Expect(routable.size, 1)
        @Expect(routable[0].name, 'daily')
    }

    @TestCase
    func testRegisterRejectsBlankName(): Unit {
        let supervisor = Supervisor()
        var raised = false
        try{
            let _ = supervisor.register('  ', '空名字')
        }catch(e: LoomException){
            raised = true
        }
        @Expect(raised, true)
        @Expect(supervisor.routes().size, 0)
    }

    // ---------- 选路与派发 ----------

    /** 装配一个带一条 compiled 流程的 Supervisor；返回 (supervisor, host, 提示词记录) */
    private func boot(name: String, description: String,
                      reply: String): (Supervisor, SupervisorRecordingHost, ArrayList<String>) {
        Supervisor.reset()
        LoomServices.reset()
        LoomHostApi.unbind()

        let (service, flow) = compiledService(name, description)
        let host = SupervisorRecordingHost()
        LoomHostApi.bind(host)
        LoomServices.installHost(host)

        let prompts = ArrayList<String>()
        let chat = { system: String, user: String =>
            prompts.add(system + '\u{0001}' + user)
            reply
        }
        let flows = ArrayList<LoomFlow>()
        flows.add(flow)
        (Supervisor.install(service, host, chat, flows: flows), host, prompts)
    }

    @TestCase
    func testRouterPromptCarriesRoutesAndPrompt(): Unit {
        let (supervisor, _, prompts) = boot('daily', '汇总昨日提交与 issue', '{"flow":"daily"}')
        let _ = supervisor.dispatch('把今天的提交汇总一下')

        @Expect(prompts.size, 1)
        let user = prompts[0].split('\u{0001}')[1]
        @Expect(user.contains('daily'), true)
        @Expect(user.contains('汇总昨日提交与 issue'), true)
        @Expect(user.contains('sv/daily'), true)
        @Expect(user.contains('把今天的提交汇总一下'), true)
    }

    @TestCase
    func testUnparsableReplyFallsBackToNoUsable(): Unit {
        let (supervisor, host, _) = boot('daily', '汇总日报', '我认为应该用日报流程')
        let outcome = supervisor.dispatch('随便一件事')

        @Expect(outcome.kind, SupervisorOutcome.NO_USABLE)
        @Expect(host.inputs.size, 0)
    }

    @TestCase
    func testMissingFlowFieldFallsBackToNoUsable(): Unit {
        let (supervisor, host, _) = boot('daily', '汇总日报', '{"other":1}')
        let outcome = supervisor.dispatch('随便一件事')

        @Expect(outcome.kind, SupervisorOutcome.NO_USABLE)
        @Expect(host.inputs.size, 0)
    }

    @TestCase
    func testEmptyFlowNameFallsBackToNoUsable(): Unit {
        let (supervisor, host, _) = boot('daily', '汇总日报', '{"flow":""}')
        let outcome = supervisor.dispatch('随便一件事')

        @Expect(outcome.kind, SupervisorOutcome.NO_USABLE)
        @Expect(host.inputs.size, 0)
    }

    @TestCase
    func testUnknownFlowNameFallsBackToNoUsable(): Unit {
        let (supervisor, host, _) = boot('daily', '汇总日报', '{"flow":"ghost"}')
        let outcome = supervisor.dispatch('随便一件事')

        @Expect(outcome.kind, SupervisorOutcome.NO_USABLE)
        @Expect(host.inputs.size, 0)
    }

    @TestCase
    func testDispatchExecutesFlowWithPromptAsData(): Unit {
        let (supervisor, host, _) = boot('daily', '汇总日报', '{"flow":"daily"}')
        let outcome = supervisor.dispatch('把今天的提交汇总一下')

        @Expect(outcome.kind, SupervisorOutcome.DISPATCHED)
        @Expect(outcome.flow, 'daily')
        @Expect(outcome.event, 'sv/daily')
        // 事件数据 → `{start.output}` → llm 步骤入参
        @Expect(host.inputs.size, 1)
        @Expect(host.inputs[0], '把今天的提交汇总一下')
    }

    @TestCase
    func testDispatchSkipsFlowThatIsNoLongerCompiled(): Unit {
        Supervisor.reset()
        LoomServices.reset()
        LoomHostApi.unbind()

        let registry = LoomRegistry()
        let (service, compiledFlow) = compiledService('daily', '汇总日报', registry: registry)
        let host = SupervisorRecordingHost()
        LoomHostApi.bind(host)
        LoomServices.installHost(host)
        let flows = ArrayList<LoomFlow>()
        flows.add(compiledFlow)
        let supervisor = Supervisor.install(service, host, { _, _ => '{"flow":"daily"}' }, flows: flows)

        // 模拟漂移：库里退回 pending，但路由表仍以为可执行
        let flow = registry.get('daily').getOrThrow()
        flow.mark(LoomStatus.PENDING)
        registry.put(flow)

        let outcome = supervisor.dispatch('把今天的提交汇总一下')
        @Expect(outcome.kind, SupervisorOutcome.NO_USABLE)
        @Expect(host.inputs.size, 0)
    }

    // ---------- 无可用流程：直接返回 / 自动新建 ----------

    private func setSwitches(supervisorOn: Bool, onNoUsable: Bool): Unit {
        Config.set<Bool>([
            (LLMConfig.LLM_SUPERVISOR, supervisorOn),
            (LLMConfig.LLM_LOOM_ON_NO_USABLE, onNoUsable)
        ])
    }

    private func clearSwitches(): Unit {
        Config.remove(LLMConfig.LLM_SUPERVISOR)
        Config.remove(LLMConfig.LLM_LOOM_ON_NO_USABLE)
    }

    /** 第一次回答选路（无可用），之后回答编排（名字留空，让框架生成） */
    private func autoBoot(prompt: String): (Supervisor, LoomService, SupervisorRecordingHost, LoomRegistry) {
        Supervisor.reset()
        LoomServices.reset()
        LoomHostApi.unbind()
        clearSwitches()

        let registry = LoomRegistry()
        let planReply = '{"status":"planned","name":"","steps":[{"id":"ask","kind":"llm",'
            + '"model":"m","system":"S","input":'
            + FlowPlan.jsonQuote('{start.output}')
            + ',"async":"false"}],"edges":[]}'
        let counter = CallCounter()
        let chat = { system: String, user: String =>
            if(counter.next() == 1){
                '{"flow":""}'
            }else{
                planReply
            }
        }
        let service = LoomService(Planner({ _, _ => planReply }), registry)
        let host = SupervisorRecordingHost()
        LoomHostApi.bind(host)
        LoomServices.installHost(host)
        (Supervisor.install(service, host, chat), service, host, registry)
    }

    @TestCase
    func testNoUsableWhenSwitchOffReturnsFixedMessage(): Unit {
        let (supervisor, _, host, registry) = autoBoot('查一下明天的天气')
        setSwitches(true, false)
        try{
            let outcome = supervisor.dispatch('查一下明天的天气')
            @Expect(outcome.kind, SupervisorOutcome.NO_USABLE)
            @Expect(outcome.message, '没有可完成此工作的流程')
            @Expect(registry.size(), 0)
            @Expect(host.inputs.size, 0)
        }finally{
            clearSwitches()
        }
    }

    @TestCase
    func testNoUsableWhenSwitchOnCreatesAndDispatches(): Unit {
        let (supervisor, service, host, registry) = autoBoot('把昨天的告警归并成一条')
        setSwitches(true, true)
        try{
            let outcome = supervisor.dispatch('把昨天的告警归并成一条')
            @Expect(outcome.kind, SupervisorOutcome.CREATED)
            @Expect(outcome.flow.startsWith('auto-'), true)
            @Expect(outcome.event, 'sv/' + outcome.flow)
            // 新流程登记进路由，且已执行一次（描述作为事件数据传到 llm 步骤）
            @Expect(service.status(outcome.flow), LoomStatus.COMPILED)
            @Expect(supervisor.eventOf(outcome.flow).getOrThrow(), 'sv/' + outcome.flow)
            @Expect(host.inputs.size, 1)
            @Expect(host.inputs[0], '把昨天的告警归并成一条')
            @Expect(registry.size(), 1)
        }finally{
            clearSwitches()
        }
    }

    @TestCase
    func testTwiceAutoCreateProducesDistinctNames(): Unit {
        let (supervisor, _, _, registry) = autoBoot('第一个需求')
        setSwitches(true, true)
        try{
            let first = supervisor.dispatch('第一个需求')
            let second = supervisor.dispatch('第二个需求')
            @Expect(first.kind, SupervisorOutcome.CREATED)
            @Expect(second.kind, SupervisorOutcome.CREATED)
            @Expect(first.flow == second.flow, false)
            @Expect(supervisor.routes().size, 2)
            @Expect(registry.size(), 2)
        }finally{
            clearSwitches()
        }
    }

    @TestCase
    func testAutoCreateStopsAtClarifying(): Unit {
        // 编排返回需要澄清：不登记、不执行
        Supervisor.reset()
        LoomServices.reset()
        LoomHostApi.unbind()
        let registry = LoomRegistry()
        let clarify = '{"status":"need_clarification","round":1,"questions":[{"id":"q1","question":"发给谁？","blocking":true}]}'
        let counter = CallCounter()
        let chat = { system: String, user: String =>
            if(counter.next() == 1){ '{"flow":""}' } else { clarify }
        }
        let service = LoomService(Planner({ _, _ => clarify }), registry)
        let host = SupervisorRecordingHost()
        LoomHostApi.bind(host)
        LoomServices.installHost(host)
        let supervisor = Supervisor.install(service, host, chat)

        setSwitches(true, true)
        try{
            let outcome = supervisor.dispatch('做一件说不清的事')
            @Expect(outcome.kind, SupervisorOutcome.CLARIFYING)
            @Expect(supervisor.routes().size, 0)
            @Expect(host.inputs.size, 0)
            // 流程以 clarifying 落库，但不在路由表里
            @Expect(registry.size(), 1)
        }finally{
            clearSwitches()
        }
    }

    // ---------- 生命周期联动 ----------

    @TestCase
    func testTapIsNoopWithoutInstall(): Unit {
        Supervisor.reset()
        let flow = LoomFlow('daily', description: '汇总日报')
        flow.mark(LoomStatus.COMPILED)
        Supervisor.tap(flow)
        @Expect(Supervisor.current().isNone(), true)
    }

    @TestCase
    func testConfirmRegistersAndDeleteRemoves(): Unit {
        Supervisor.reset()
        LoomServices.reset()
        LoomHostApi.unbind()

        let registry = LoomRegistry()
        let planJson = llmPlanJson('daily')
        let service = LoomService(Planner({ _, _ => planJson }), registry)
        let host = SupervisorRecordingHost()
        LoomHostApi.bind(host)
        LoomServices.installHost(host)
        let supervisor = Supervisor.install(service, host, { _, _ => '{"flow":"daily"}' })

        let flow = LoomFlow('daily', description: '汇总日报')
        flow.planJson = planJson
        flow.mark(LoomStatus.PENDING)
        registry.put(flow)

        // pending 就不该出现在选路候选里
        @Expect(supervisor.routable().size, 0)
        let _ = service.confirmFlow('daily')
        @Expect(supervisor.routes().size, 1)
        @Expect(supervisor.routable().size, 1)

        let _ = service.delete('daily')
        @Expect(supervisor.routes().size, 0)
    }

    /** 端到端冒烟：两条流程 → 命中 daily 执行 → 无命中按配置新建并执行 */
    @TestCase
    func testSmokeTwoFlowsThenAutoCreate(): Unit {
        Supervisor.reset()
        LoomServices.reset()
        LoomHostApi.unbind()

        let registry = LoomRegistry()
        let service = LoomService(Planner({ _, _ => llmPlanJson('smoke') }), registry)
        let daily = LoomFlow('daily', description: '汇总日报')
        daily.planJson = llmPlanJson('daily')
        daily.mark(LoomStatus.PENDING)
        registry.put(daily)
        let weekly = LoomFlow('weekly', description: '汇总周报')
        weekly.planJson = llmPlanJson('weekly')
        weekly.mark(LoomStatus.PENDING)
        registry.put(weekly)
        let _ = service.confirmFlow('daily')
        let _ = service.confirmFlow('weekly')

        let host = SupervisorRecordingHost()
        LoomHostApi.bind(host)
        LoomServices.installHost(host)
        let reply = ReplyBox()
        let flows = ArrayList<LoomFlow>()
        flows.add(registry.get('daily').getOrThrow())
        flows.add(registry.get('weekly').getOrThrow())
        let supervisor = Supervisor.install(service, host, { _, _ => reply.value }, flows: flows)

        setSwitches(true, true)
        try{
            // 第一段：命中已有流程
            reply.value = '{"flow":"daily"}'
            let hit = supervisor.dispatch('把今天的提交汇总一下')
            @Expect(hit.kind, SupervisorOutcome.DISPATCHED)
            @Expect(hit.flow, 'daily')
            @Expect(host.inputs.size, 1)

            // 第二段：无命中 → 自动新建并执行
            reply.value = '{"flow":""}'
            let miss = supervisor.dispatch('把告警按服务归并')
            @Expect(miss.kind, SupervisorOutcome.CREATED)
            @Expect(miss.flow.startsWith('auto-'), true)
            @Expect(host.inputs.size, 2)
            @Expect(host.inputs[1], '把告警按服务归并')
            @Expect(supervisor.routes().size, 3)
        }finally{
            clearSwitches()
        }
    }

    /** 自动新建的名字撞上已有流程时顺延 `-2`（注入固定时钟，避免依赖真实秒数） */
    @TestCase
    func testAutoCreateNameCollisionSuffixes(): Unit {
        Supervisor.reset()
        LoomServices.reset()
        LoomHostApi.unbind()

        let registry = LoomRegistry()
        let planJson = llmPlanJson('auto-1000')
        let taken = LoomFlow('auto-1000', description: '已存在的自动流程')
        taken.planJson = planJson
        taken.mark(LoomStatus.PENDING)
        registry.put(taken)

        let service = LoomService(Planner({ _, _ => planJson }), registry)
        let host = SupervisorRecordingHost()
        LoomHostApi.bind(host)
        LoomServices.installHost(host)
        let counter = CallCounter()
        let chat = { system: String, user: String =>
            if(counter.next() == 1){
                '{"flow":""}'
            }else{
                planJson
            }
        }
        let supervisor = Supervisor.install(service, host, chat, clock: { => 1000 })

        setSwitches(true, true)
        try{
            let outcome = supervisor.dispatch('没有任何流程能做的活')
            @Expect(outcome.kind, SupervisorOutcome.CREATED)
            @Expect(outcome.flow, 'auto-1000-2')
            @Expect(service.status('auto-1000'), LoomStatus.PENDING)
        }finally{
            clearSwitches()
        }
    }

    @TestCase
    func testClosedStateKeepsLoomUsable(): Unit {
        Supervisor.reset()
        LoomServices.reset()
        LoomHostApi.unbind()
        clearSwitches()

        let registry = LoomRegistry()
        let planJson = llmPlanJson('daily')
        let service = LoomService(Planner({ _, _ => planJson }), registry)
        let flow = LoomFlow('daily', description: '汇总日报')
        flow.planJson = planJson
        flow.mark(LoomStatus.PENDING)
        registry.put(flow)

        let _ = service.confirmFlow('daily')
        @Expect(service.status('daily'), LoomStatus.COMPILED)
        let _ = service.delete('daily')
        @Expect(Supervisor.current().isNone(), true)
    }
}

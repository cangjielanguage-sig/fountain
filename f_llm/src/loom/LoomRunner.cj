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
import std.sync.*

import fountain::f_data.*

import fountain::f_egraph.base.*

/** 记录最后一个步骤的输出（多线程下用锁保护） */
class LastEventBox {
    private let mutex = Mutex()
    private var last: ?Event = None

    public func set(event: Event): Unit {
        synchronized(mutex){
            last = Some(event)
        }
    }

    public func get(): ?Event {
        let box = EventBox()
        synchronized(mutex){
            box.value = last
        }
        box.value
    }
}

class EventBox {
    public var value: ?Event = None
}

class JudgeBox {
    public var value: Bool = false
}

class SeqBox {
    public var value: Int64 = 0
}

/** 本次执行的结果：正常走完为 success，抛异常为 failed */
class OutcomeBox {
    public var value: String = 'success'
}

/**
 * 汇聚屏障：入度 > 1 的步骤要等所有前驱事件到齐才执行。
 *
 * `AsyncFlow` 下分支并发到达，计数必须在锁内维护。
 */
class JoinBarrier {
    private let mutex = Mutex()
    private let expected: HashMap<String, Int64>
    private var arrived = HashMap<String, Int64>()

    init(expected: HashMap<String, Int64>) {
        this.expected = expected
    }

    public func release(id: String): Bool {
        let box = JudgeBox()
        synchronized(mutex){
            let need = expected.get(id) ?? 1
            if(need <= 1){
                box.value = true
            }else{
                let current = (arrived.get(id) ?? 0) + 1
                if(current >= need){
                    arrived[id] = 0
                    box.value = true
                }else{
                    arrived[id] = current
                    box.value = false
                }
            }
        }
        box.value
    }
}

/**
 * 流程执行器（§9.6 的执行段）。
 *
 * 每个步骤是一个 `QueuedClosureTask`，结果按计划的边改写成**下一个步骤 id** 的事件；
 * 出度为 0 的步骤改写成 `End` 事件收尾。分叉返回 `MultiEvent`，汇聚用 [JoinBarrier] 等齐。
 *
 * 两种派发方式：
 * - `parallel = false`（默认）：`ImmediateFlow`，同步派发，分叉按顺序 emit；
 * - `parallel = true`：`AsyncFlow`，分叉的分支可并发执行，`start` 后 `get()` 等结束。
 */
public class LoomRunner {
    private let compiler: LoomCompiler

    public init(compiler!: LoomCompiler = LoomCompiler()) {
        this.compiler = compiler
    }

    /**
     * @param input 起始事件（通常是 StartEvent）
     * @param parallel 是否用 `AsyncFlow` 并发执行分叉
     * @return 最后一个步骤产出的事件（名字为步骤 id）
     */
    public func run(plan: FlowPlan, host: LoomHost, input: Event,
                    parallel!: Bool = false,
                    skills!: Array<String> = Array<String>()): Event {
        plan.validate()
        let order = topologicalOrder(plan)
        if(order.isEmpty()){
            throw LoomException('loom plan has no steps to run')
        }
        let steps = compiler.compileSteps(plan)
        runCompiled(plan, steps, host, input, parallel: parallel, skills: skills)
    }

    /** 用已编译好的步骤闭包执行（`LoomProgram` 复用，避免重复编译） */
    public func runCompiled(plan: FlowPlan, steps: HashMap<String, (Event) -> Event>,
                            host: LoomHost, input: Event,
                            parallel!: Bool = false,
                            skills!: Array<String> = Array<String>()): Event {
        let order = topologicalOrder(plan)
        let successors = successorsOf(plan)
        let barrier = JoinBarrier(indegreesOf(plan))
        let record = LastEventBox()
        let tag = nextTag(plan.name)

        let bodies = HashMap<String, (Event) -> Event>()
        let producing = HashMap<String, Array<String>>()
        for(id in order){
            let compiled = match(steps.get(id)){
                case Some(value) => value
                case None => throw LoomException('loom step is not compiled: ${id}')
            }
            let next = successors.get(id) ?? ArrayList<String>()
            let sink = next.isEmpty()
            producing[id] = if(sink){ [EventType.End.toString()] }else{ next.toArray() }
            bodies[id] = bodyOf(id, next, sink, compiled, barrier, record)
        }

        // 计划指定的「人格/提示词」：先按提示词名查库，查不到就当字面文本；
        // persona 为空时回落到该用户 character 里记录的 key
        let userId = LoomMemoryPolicy.effective().userId
        var personaKey = plan.persona
        if(personaKey.trimAscii().isEmpty()){
            personaKey = characterKeyOf(userId)
        }
        let persona = resolvePersona(personaKey)
        if(!persona.isEmpty()){
            LoomHostApi.setPersona(persona)
        }
        // 技能：显式给了标题就按标题加载；没给就按任务描述自动挑（SkillCatalog）
        let policy = LoomMemoryPolicy.effective()
        let taskText = taskTextOf(plan, input)
        let selected = ArrayList<String>()
        for(title in skills){
            selected.add(title)
        }
        if(selected.isEmpty() && policy.autoSkills){
            for(hit in SkillCatalog.search(taskText, topK: policy.skillTopK,
                                           minScore: policy.skillMinScore)){
                selected.add(hit.title)
            }
        }
        let skillBlock = resolveSkills(selected)
        if(!skillBlock.isEmpty()){
            LoomHostApi.setSkills(skillBlock)
        }
        if(policy.enabled){
            LoomContextLog.begin()
        }
        LoomHostApi.bind(host)
        let outcome = OutcomeBox()
        try{
            if(parallel){
                runAsync(plan, order, bodies, producing, tag, input)
            }else{
                runSync(plan, order, bodies, producing, tag, input)
            }
        }catch(error: Exception){
            // 失败的流程也要留下经验：先记结果，再原样抛回调用方
            outcome.value = 'failed'
            throw error
        }finally{
            // 先取快照并关闭记录，再解绑——提炼阶段自己发的模型请求不会被记进来
            let turns = LoomContextLog.snapshot()
            LoomContextLog.clear()
            LoomHostApi.unbind()
            LoomHostApi.clearPersona()
            LoomHostApi.clearSkills()
            if(policy.enabled && !turns.isEmpty()){
                try{
                    LoomMemoryExtractor.extract(plan.name, turns, host, policy,
                                                outcome: outcome.value)
                }catch(error: Exception){
                    // 记忆提炼失败不影响流程结果
                    ()
                }
            }
        }
        match(record.get()){
            case Some(event) => event
            case None => DummyEvent.instance
        }
    }

    private func runSync(plan: FlowPlan, order: ArrayList<String>,
                         bodies: HashMap<String, (Event) -> Event>,
                         producing: HashMap<String, Array<String>>,
                         tag: String, input: Event): Unit {
        let flow = ImmediateFlow(category: 'loom', tag: tag)
        flow.registerStart(order[0])
        for(id in order){
            flow.registerTask(QueuedClosureTask(id, [id], producing[id],
                                                flow.getDispatcher(), bodies[id]))
        }
        flow.registerEnd()
        try{
            match(input as DataEvent){
                case Some(event) => flow.start(event.data)
                case None => flow.start(input)
            }
        }finally{
            release(flow)
        }
    }

    private static let asyncInitMutex = Mutex()
    private static var asyncReady = false

    /** `AsyncFlow` 依赖全局 `AsyncDispatcher`，首次使用前初始化一次 */
    private static func ensureAsyncDispatcher(): Unit {
        synchronized(asyncInitMutex){
            if(!asyncReady){
                AsyncFlow.initDispatcher()
                asyncReady = true
            }
        }
    }

    private func runAsync(plan: FlowPlan, order: ArrayList<String>,
                          bodies: HashMap<String, (Event) -> Event>,
                          producing: HashMap<String, Array<String>>,
                          tag: String, input: Event): Unit {
        ensureAsyncDispatcher()
        let flow = AsyncFlow(category: 'loom', tag: tag)
        flow.registerStart(order[0])
        for(id in order){
            flow.registerTask(QueuedClosureTask(id, [id], producing[id],
                                                flow.getDispatcher(), bodies[id]))
        }
        flow.registerEnd()
        try{
            let waiter = match(input as DataEvent){
                case Some(event) => flow.start(event.data)
                case None => flow.start(input)
            }
            // 异步派发需要显式等待结束（EndExecutor 由 sink 步骤的 End 事件触发）
            waiter.get()
        }finally{
            release(flow)
        }
    }

    private static func release(flow: Flow<EndExecutorGetter>): Unit {
        ()
    }

    private static func release(flow: AsyncFlow): Unit {
        try{
            flow.remove()
        }catch(error: Exception){
            ()
        }
    }

    private static func release(flow: ImmediateFlow): Unit {
        try{
            flow.remove()
        }catch(error: Exception){
            ()
        }
    }

    /** 单步骤的任务体：屏障 → 执行 → 按边改写事件名 */
    private static func bodyOf(id: String, next: ArrayList<String>, sink: Bool,
                               compiled: (Event) -> Event, barrier: JoinBarrier,
                               record: LastEventBox): (Event) -> Event {
        { e: Event =>
            // 汇聚节点：前驱没到齐就吞掉本次事件（Dummy 会被派发循环跳过）
            if(!barrier.release(id)){
                return DummyEvent.instance
            }
            let produced = compiled(e)
            record.set(produced)
            let data = match(produced as DataEvent){
                case Some(event) => event.data
                case None => ''
            }
            if(sink){
                DataEvent(eventType: EventType.End, category: e.category, tag: e.tag,
                          name: EventType.End.toString(), data: data)
            }else if(next.size == 1){
                DataEvent(eventType: EventType.Task, category: e.category, tag: e.tag,
                          name: next[0], data: data)
            }else{
                // 分叉：交给 registerMultiEventTask 注册的 Multi 执行器逐条 emit
                let events = ArrayList<Event>()
                for(target in next){
                    events.add(DataEvent(eventType: EventType.Task, category: e.category,
                                         tag: e.tag, name: target, data: data))
                }
                MultiEvent(category: e.category, tag: e.tag,
                           name: EventType.Multi.toString(), events: events)
            }
        }
    }

    private static let tagMutex = Mutex()
    private static var tagSeq: Int64 = 0

    /** 每次执行用一个新 tag，避免复用全局缓存里的旧派发器 */
    private static func nextTag(name: String): String {
        let box = SeqBox()
        synchronized(tagMutex){
            tagSeq++
            box.value = tagSeq
        }
        '${name}#${box.value}'
    }

    /**
     * 解析计划里的 `persona`：先按「提示词名」查 `prompt.latest`，命中的取 content；
     * 查不到（或存储未装配）就当字面人格文本用。
     */
    private static func resolvePersona(value: String): String {
        if(value.trimAscii().isEmpty()){
            return ''
        }
        try{
            let text = LoomHostApi.callStore('prompt', 'latest',
                '{"name":${FlowPlan.jsonQuote(value)}}')
            if(!text.trimAscii().isEmpty()){
                match(JsonValue.fromStr(text) as JsonObject){
                    case Some(json) =>
                        match(json.get('content')){
                            case Some(field) =>
                                match(field as JsonString){
                                    case Some(item) => return item.value
                                    case None => ()
                                }
                            case None => ()
                        }
                    case None => ()
                }
            }
        }catch(error: Exception){
            ()
        }
        value
    }

    /** 用户当前配置的人格 key（character 库为空时返回空串） */
    private static func characterKeyOf(userId: Int64): String {
        if(userId <= 0){
            return ''
        }
        try{
            let raw = LoomHostApi.callStore('character', 'get', '{"userId":${userId}}')
            if(!raw.trimAscii().isEmpty()){
                match(JsonValue.fromStr(raw) as JsonObject){
                    case Some(json) => return fieldOf(json, 'characterKey')
                    case None => ()
                }
            }
        }catch(error: Exception){
            ()
        }
        ''
    }

    /** 自动挑技能用的任务文本：计划备注 + 起始输入 */
    private static func taskTextOf(plan: FlowPlan, input: Event): String {
        var text = plan.notes
        match(input as DataEvent){
            case Some(event) =>
                let value = dataText(event.data)
                if(!value.isEmpty()){
                    text = if(text.isEmpty()){ value }else{ '${text}\n${value}' }
                }
            case None => ()
        }
        text
    }

    private static func dataText(data: Any): String {
        // 只有字符串才是可检索的任务描述；其它类型（结构化数据）不参与技能匹配
        match(data as String){
            case Some(value) => value
            case None => ''
        }
    }

    /** 按标题把技能正文拼成注入块；未命中的技能直接跳过 */
    private static func resolveSkills(titles: ArrayList<String>): String {
        var text = ''
        for(title in titles){
            try{
                let raw = LoomHostApi.callStore('skill', 'load',
                    '{"title":${FlowPlan.jsonQuote(title)}}')
                if(raw.trimAscii().isEmpty()){
                    continue
                }
                match(JsonValue.fromStr(raw) as JsonObject){
                    case Some(json) =>
                        let details = fieldOf(json, 'details')
                        if(!details.isEmpty()){
                            text += '- ${title}：${details}\n'
                        }
                    case None => ()
                }
            }catch(error: Exception){
                ()
            }
        }
        text
    }

    private static func fieldOf(json: JsonObject, key: String): String {
        match(json.get(key)){
            case Some(value) =>
                match(value as JsonString){
                    case Some(text) => text.value
                    case None => ''
                }
            case None => ''
        }
    }

    /** 每个步骤的后继列表（保持计划中的顺序） */
    private static func successorsOf(plan: FlowPlan): HashMap<String, ArrayList<String>> {
        let result = HashMap<String, ArrayList<String>>()
        for(edge in plan.edges){
            let list = result.get(edge.from) ?? ArrayList<String>()
            list.add(edge.to)
            result[edge.from] = list
        }
        result
    }

    /** 每个步骤的入度：> 1 表示汇聚节点，需要屏障 */
    private static func indegreesOf(plan: FlowPlan): HashMap<String, Int64> {
        let result = HashMap<String, Int64>()
        for(step in plan.steps){
            result[step.id] = 0
        }
        for(edge in plan.edges){
            result[edge.to] = (result.get(edge.to) ?? 0) + 1
        }
        result
    }

    /** Kahn 拓扑排序；有环时抛错（`validate` 只查自环与缺失端点） */
    public static func topologicalOrder(plan: FlowPlan): ArrayList<String> {
        let indegree = HashMap<String, Int64>()
        let next = HashMap<String, ArrayList<String>>()
        for(item in plan.steps){
            indegree[item.id] = 0
        }
        for(edge in plan.edges){
            let list = next.get(edge.from) ?? ArrayList<String>()
            list.add(edge.to)
            next[edge.from] = list
            indegree[edge.to] = (indegree.get(edge.to) ?? 0) + 1
        }
        let ready = ArrayList<String>()
        for(item in plan.steps){
            if((indegree.get(item.id) ?? 0) == 0){
                ready.add(item.id)
            }
        }
        let order = ArrayList<String>()
        while(!ready.isEmpty()){
            let current = ready.remove(at: 0)
            order.add(current)
            match(next.get(current)){
                case Some(items) =>
                    for(item in items){
                        let left = (indegree.get(item) ?? 0) - 1
                        indegree[item] = left
                        if(left == 0){
                            ready.add(item)
                        }
                    }
                case None => ()
            }
        }
        if(order.size != plan.steps.size){
            throw LoomException('loom plan contains a cycle, cannot execute')
        }
        order
    }
}

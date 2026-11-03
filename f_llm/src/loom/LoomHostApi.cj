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

import fountain::f_egraph.base.*

/**
 * 生成源码调用的静态宿主入口。
 *
 * 为什么不用 `host` 参数：JIT 编译的步骤闭包形参越少越好，`host` 作为接口参数
 * 需要额外注册；这里的静态入口在编译前绑定一次，生成的代码只依赖类名。
 *
 * 约束：**单线程使用**。执行前 `bind`，执行完 `unbind`；并发流程需各自持有独立进程
 * 或改为显式传参（当前 loom 的执行模型是单流程串行）。
 */
/** `synchronized` 的块是 Unit 语义，返回值用持有者带出 */
class TextBox {
    public var value: String = ''
}

class GatewayBox {
    public var value: ?(String, String, String) -> String = None
}

public class LoomHostApi {
    private static let mutex = Mutex()
    private static var current: ?LoomHost = None
    /** 已执行步骤的输出：`{id.output}` 模板从这里取值 */
    private static var values = HashMap<String, String>()

    private init() {
    }

    public static func bind(host: LoomHost): Unit {
        synchronized(mutex){
            current = Some(host)
            values = HashMap<String, String>()
        }
    }

    public static func unbind(): Unit {
        synchronized(mutex){
            current = None
            values = HashMap<String, String>()
        }
    }

    /**
     * 模板替换：`{stepId.output}` 换成该步骤已产出的数据，`{start.output}` 换成进入本步骤的事件数据。
     *
     * 未命中的占位符原样保留——让模型/开发者看到「这里没取到值」，比静默替换成空串好排错。
     */
    public static func render(template: String, e: Event): String {
        // 事件本身的数据：定时任务/外部触发时由 `StartEvent.data` 携带
        let fromEvent = match(e as DataEvent){
            case Some(event) => textOf(event.data)
            case None => ''
        }
        let box = TextBox()
        synchronized(mutex){
            var text = template
            for((name, value) in values){
                text = text.replace('{${name}.output}', value)
            }
            if(!fromEvent.isEmpty()){
                text = text.replace('{start.output}', fromEvent)
            }
            box.value = text
        }
        box.value
    }

    public static func callTool(name: String, argsJson: String): String {
        match(current){
            case Some(host) => host.callTool(name, argsJson)
            case None => throw LoomException('loom host is not bound, cannot call tool: ${name}')
        }
    }

    /** 存储网关：由装配方注入（记忆/知识/经验的读写都走它） */
    private static var storeGateway: ?(String, String, String) -> String = None

    public static func installStore(gateway: (String, String, String) -> String): Unit {
        synchronized(mutex){
            storeGateway = Some(gateway)
        }
    }

    public static func resetStore(): Unit {
        synchronized(mutex){
            storeGateway = None
        }
    }

    /** `kind` ∈ memory|knowledge|skill|experience，`op` 由网关解释，`payload` 为 JSON */
    public static func callStore(kind: String, op: String, payload: String): String {
        let box = GatewayBox()
        synchronized(mutex){
            box.value = storeGateway
        }
        match(box.value){
            case Some(fn) => fn(kind, op, payload)
            case None => throw LoomException('loom store gateway is not installed: ${kind}.${op}')
        }
    }

    public static func callLlm(model: String, system: String, input: String): String {
        // 计划指定的人格/提示词与技能：拼在 system 前面，空则不影响
        let persona = currentPersonaText()
        let skills = currentSkillsText()
        var prefix = persona
        if(!skills.isEmpty()){
            prefix = if(prefix.isEmpty()){ '可用技能：\n${skills}' }
                     else{ '${prefix}\n\n可用技能：\n${skills}' }
        }
        let fullSystem = if(prefix.isEmpty()){ system }else if(system.isEmpty()){ prefix }
                         else{ '${prefix}\n${system}' }
        match(current){
            case Some(host) =>
                let output = host.callLlm(model, fullSystem, input)
                // 临时上下文：流程执行期记下每一次交互，结束时统一提炼记忆/经验
                LoomContextLog.record(LlmTurn(model, fullSystem, input, output))
                output
            case None => throw LoomException('loom host is not bound, cannot call llm: ${model}')
        }
    }

    /** 本次流程生效的人格/提示词文本（已解析） */
    private static var personaText: String = ''

    public static func setPersona(text: String): Unit {
        synchronized(mutex){
            personaText = text
        }
    }

    public static func clearPersona(): Unit {
        synchronized(mutex){
            personaText = ''
        }
    }

    public static func currentPersonaText(): String {
        let box = TextBox()
        synchronized(mutex){
            box.value = personaText
        }
        box.value
    }

    /** 本次流程加载的技能正文（`标题：正文` 逐行拼接） */
    private static var skillText: String = ''

    public static func setSkills(text: String): Unit {
        synchronized(mutex){
            skillText = text
        }
    }

    public static func clearSkills(): Unit {
        synchronized(mutex){
            skillText = ''
        }
    }

    public static func currentSkillsText(): String {
        let box = TextBox()
        synchronized(mutex){
            box.value = skillText
        }
        box.value
    }

    /**
     * 生成事件：f_jit 不支持命名实参，所以由宿主代建 `TaskEvent`。
     *
     * 同时把输出记进 `values`，供后续步骤的 `{id.output}` 模板取值。
     */
    public static func taskEvent(e: Event, name: String, data: Any): Event {
        synchronized(mutex){
            values[name] = textOf(data)
        }
        TaskEvent(category: e.category, tag: e.tag, name: name, data: data)
    }

    /** 供测试/诊断：某步骤当前记录的输出 */
    public static func valueOf(name: String): String {
        let box = TextBox()
        synchronized(mutex){
            box.value = values.get(name) ?? ''
        }
        box.value
    }

    private static func textOf(data: Any): String {
        match(data as String){
            case Some(text) => text
            case None =>
                match(data as Int64){
                    case Some(number) => number.toString()
                    case None => ''
                }
        }
    }
}

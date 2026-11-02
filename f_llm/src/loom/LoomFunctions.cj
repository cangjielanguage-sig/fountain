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

import fountain::f_bean.*
import fountain::f_bean.macros.*
import fountain::f_data.macros.*
import fountain::f_egraph.base.*

import fountain::f_llm.tool.*

/** 服务与宿主的进程级持有者：启动时安装，工具调用时取用 */
public class LoomServices {
    private static var installed: ?LoomService = None
    private static var host: ?LoomHost = None

    private init() {
    }

    public static func install(service: LoomService): Unit {
        installed = Some(service)
    }

    public static func installHost(value: LoomHost): Unit {
        host = Some(value)
    }

    public static func reset(): Unit {
        installed = None
        host = None
    }

    public static func current(): ?LoomService {
        installed
    }

    public static func currentHost(): ?LoomHost {
        host
    }
}

@DataAssist[props fields]
public class LoomExecuteParam {
    @JsonStringSchema[description:'流程下一步的事件名称']
    private var nextEvent: String = ''
    @JsonStringSchema[description:'流程标识，全局唯一；confirm 时按它找回已存流程']
    private var name: String = ''
    @JsonStringSchema[description:'自然语言任务描述；confirm=true 时可留空']
    private var description: String = ''
    @JsonArraySchema[description:'本流程可用的工具白名单']
    private var tools: ArrayList<String> = ArrayList<String>()
    @JsonArraySchema[description:'本流程可用的 MCP 白名单']
    private var mcps: ArrayList<String> = ArrayList<String>()
    @JsonStringSchema[description:'人格 key；留空用默认人格']
    private var persona: String = ''
    @JsonStringSchema[description:'"true" 时只预览不编译（默认）；预览返回计划与闭包原文']
    private var dryRun: String = ''
    @JsonStringSchema[description:'"true" 时编译并注册；默认 false，只做预览']
    private var confirm: String = ''
    @JsonStringSchema[description:'"true" 且 confirm=true 时，编译后立即执行一次；默认 false']
    private var execute: String = ''
    @JsonStringSchema[description:'"true" 允许分叉步骤并发执行；默认 false（串行）']
    private var parallel: String = ''
}

/**
 * `loomExecute`：把自然语言任务拆成流程。
 *
 * - `confirm=false`：Planner + CodeGen，落 pending，返回闭包原文（§9.6 的硬要求）；
 * - `confirm=true`：按 `name` 编译已存流程，成功后标 compiled；
 * - 描述有歧义：返回澄清问题，不生成源码。
 */
@Bean
public class LoomExecuteFunction <: FunctionCalling<LoomExecuteParam> {
    public prop name: String {
        get() {
            'loomExecute'
        }
    }

    public prop description: String {
        get() {
            '把自然语言任务拆成可执行流程：confirm=false 返回计划与源码预览，confirm=true 编译注册。'
        }
    }

    public func call(params: LoomExecuteParam): FunctionResult {
        let service = match(LoomServices.current()){
            case Some(value) => value
            case None => return FunctionResult(event: params.nextEvent,
                result: '[loomExecute] loom service is not installed; call LoomServices.install first')
        }
        let confirm = params.confirm.trimAscii().toAsciiLower() == 'true'
        let isParallel = params.parallel.trimAscii().toAsciiLower() == 'true'
        let result = if(confirm){
            service.confirmFlow(params.name)
        }else{

            if(params.description.trimAscii().isEmpty()){
                return FunctionResult(event: params.nextEvent,
                    result: '[loomExecute] description is required when confirm=false')
            }
            service.execute(LoomRequest(params.name, params.description,
                tools: params.tools.toArray(), mcps: params.mcps.toArray(),
                persona: params.persona, parallel: isParallel), confirm: false)
        }
        var text = summary(result)
        if(confirm && params.execute.trimAscii().toAsciiLower() == 'true'){
            match(LoomServices.currentHost()){
                case Some(host) =>
                    let event = service.executeNow(params.name, host,
                        StartEvent(category: 'loom', tag: params.name, name: 'start',
                                   data: params.description), parallel: isParallel)
                    text += '\nexecuted: ${event.name}'
                case None =>
                    text += '\nexecute skipped: no loom host installed'
            }
        }
        FunctionResult(event: params.nextEvent, result: text)
    }

    private static func summary(result: LoomResult): String {
        if(result.needsClarification){
            var text = '[loomExecute] need clarification for ${result.name}\n'
            for(item in result.questions){
                text += '- ${item.id}: ${item.question}\n'
            }
            return text
        }
        var text = '[loomExecute] ${result.status}: ${result.name}\n'
        text += 'steps: ${result.stepSources.size}\n'
        if(!result.planJson.isEmpty()){
            text += 'plan:\n${result.planJson}\n'
        }
        if(result.status == 'pending'){
            text += 'source:\n${result.flowSource}\n'
            text += 'call loomExecute with confirm=true to compile.'
        }
        text
    }
}

@DataAssist[props fields]
public class LoomDeleteParam {
    @JsonStringSchema[description:'流程下一步的事件名称']
    private var nextEvent: String = ''
    @JsonStringSchema[description:'要删除的流程标识']
    private var name: String = ''
}

/** `loomDelete`：从注册表移除流程定义 */
@Bean
public class LoomDeleteFunction <: FunctionCalling<LoomDeleteParam> {
    public prop name: String {
        get() {
            'loomDelete'
        }
    }

    public prop description: String {
        get() {
            '删除已注册的 loom 流程定义；正在运行的实例不受影响。'
        }
    }

    public func call(params: LoomDeleteParam): FunctionResult {
        let service = match(LoomServices.current()){
            case Some(value) => value
            case None => return FunctionResult(event: params.nextEvent,
                result: '[loomDelete] loom service is not installed')
        }
        if(params.name.trimAscii().isEmpty()){
            return FunctionResult(event: params.nextEvent,
                result: '[loomDelete] name is required')
        }
        let removed = service.delete(params.name)
        FunctionResult(event: params.nextEvent,
                       result: '[loomDelete] ${params.name}: removed=${removed}')
    }
}

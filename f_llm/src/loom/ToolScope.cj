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

/**
 * 解析/校验流程可用的工具集合（§9.1 `ToolScope`）。
 *
 * 计划里的 `tools` / `mcps` 是白名单：只能收窄，不能凭空引入。
 * 与具体注册表解耦（`available` 由调用方从 `FunctionMediator` / `McpToolSource` 取），
 * 便于单测。
 */
public class ToolScope {
    /**
     * 校验并返回交集。
     *
     * @param kind       `tool` / `mcp`，仅用于错误信息
     * @param requested  计划里声明的名字
     * @param available  当前进程实际注册的名字
     * @throws LoomException 计划声明了未注册的名字
     */
    public static func check(kind: String, requested: Array<String>,
                             available: Collection<String>): ArrayList<String> {
        let known = HashMap<String, Bool>()
        for(item in available){
            known[item] = true
        }
        let result = ArrayList<String>()
        for(item in requested){
            if(item.trimAscii().isEmpty()){
                throw LoomException('loom ${kind} whitelist contains blank name')
            }
            if(!known.contains(item)){
                throw LoomException('loom ${kind} is not registered: ${item}')
            }
            if(!result.contains(item)){
                result.add(item)
            }
        }
        result
    }

    /** 校验计划里 step 引用的工具/模型都在白名单内 */
    public static func verifyPlan(plan: FlowPlan, tools: Array<String>,
                                  availableTools: Collection<String>): Unit {
        plan.validate()
        let allowed = HashMap<String, Bool>()
        for(item in tools){
            allowed[item] = true
        }
        let known = HashMap<String, Bool>()
        for(item in availableTools){
            known[item] = true
        }
        for(step in plan.steps){
            if(step.kind != 'tool' && step.kind != 'mcp'){
                continue
            }
            if(!allowed.contains(step.tool)){
                throw LoomException(
                    'step ${step.id} uses ${step.kind} "${step.tool}" outside the flow whitelist')
            }
            if(!known.contains(step.tool)){
                throw LoomException(
                    'step ${step.id} uses ${step.kind} "${step.tool}" which is not registered')
            }
        }
    }
}

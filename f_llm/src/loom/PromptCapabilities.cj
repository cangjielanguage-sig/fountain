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

import fountain::f_llm.tool.*

/**
 * 编排提示词末尾的「能力清单」。
 *
 * 模型不可能凭常识知道宿主有什么；不告诉它，拆出来的步骤就会虚构工具名，
 * 或者把本该自动查的事写成澄清问题。因此无论用内置提示词还是自定义提示词，
 * 这里生成的清单都会追加在 system prompt 末尾。
 */
public class PromptCapabilities {
    private init() {
    }

    /**
     * 当前可用的能力清单。
     *
     * @param allowed 非空时只列这些工具（任务描述里 `tools` 收窄）；为空则列全部
     */
    public static func render(allowed!: ?Array<String> = None): String {
        let registered = FunctionMediator.names()
        let tools = match(allowed){
            case Some(whitelist) =>
                let picked = ArrayList<String>()
                for(name in registered){
                    if(whitelist.contains(name)){
                        picked.add(name)
                    }
                }
                picked
            case None => registered
        }
        var text = '可用能力（运行期按需调用，禁止虚构不存在的工具名）：\n'
        text += '- loomCallTool(name, argsJson)：调用已注册的 tool_call 或 MCP 工具\n'
        text += '- loomCallLlm(model, system, input)：调用大模型\n'
        text += '- loomStore(kind, op, payload)：'
        text += 'kind = memory | knowledge | skill | experience | prompt | character | evolution；'
        text += 'op = search | get | list | load | add | upsert | remove | docIds | count | latest | put | set | reset | by_skill\n'
        text += '- 计划的 persona 可写提示词名（取 prompt.latest 正文）或字面文本，执行时会拼在每次模型调用的 system 前\n'
        if(tools.isEmpty()){
            text += '已注册工具：（当前没有）\n'
        }else{
            text += '已注册工具：${tools.toString()}\n'
        }
        text += '步骤需要事实时，优先排一个调用上述能力的步骤去查，不要先问用户。'
        text
    }
}

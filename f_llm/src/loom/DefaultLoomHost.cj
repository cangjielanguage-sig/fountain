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

import fountain::f_data.*
import fountain::f_egraph.base.*

import fountain::f_llm.tool.*

/**
 * 生产用宿主：工具走 [FunctionMediator]，模型走注入的 chat 回调。
 *
 * chat 回调签名为 `(model, system, input) -> String`：
 * 具体用哪个模型/客户端由装配方决定（`LoomWiring`），本类不绑死 LLM 实现，
 * 便于测试与替换。
 */
public class DefaultLoomHost <: LoomHost {
    private let chat: (String, String, String) -> String

    public init(chat: (String, String, String) -> String) {
        this.chat = chat
    }

    /** 模板替换由 `LoomHostApi` 统一完成（需要跨步骤的输出表），这里原样返回 */
    public func render(template: String, e: Event): String {
        template
    }

    public func callTool(name: String, argsJson: String): String {
        let args = JsonValue.fromStr(argsJson).asObject()
        let result = FunctionMediator.call(name, args)
        match(result.result as JsonString){
            case Some(text) => text.value
            case None => ''
        }
    }

    public func callLlm(model: String, system: String, input: String): String {
        chat(model, system, input)
    }
}

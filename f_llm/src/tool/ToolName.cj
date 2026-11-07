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
package fountain::f_llm.tool

import fountain::f_llm.exception.*

/**
 * 工具名校验与 MCP 工具命名。
 *
 * 规则（评审 B8）：**不截断**。名字超长或替换后仍非法就启动失败——
 * 截断 + hash 会让日志、模型看到的工具名与 MCP server 里的真实工具名对不上，
 * 排障时要反推 hash；长度是配置问题（改短 alias 即可），不该由框架悄悄改名。
 */
public struct ToolName {
    public static const MAX_LENGTH = 64

    private init(){}

    public static func validate(name: String): Unit {
        if(name.isEmpty()){
            throw FunctionCallingException('tool name cannot be empty')
        }
        if(name.size > MAX_LENGTH){
            throw FunctionCallingException('tool name too long (${name.size} > ${MAX_LENGTH}), shorten the alias: ${name}')
        }
        for(rune in name.runes()){
            let legal = (rune >= r'a' && rune <= r'z') ||
                        (rune >= r'A' && rune <= r'Z') ||
                        (rune >= r'0' && rune <= r'9') ||
                        rune == r'_' || rune == r'-'
            if(!legal){
                throw FunctionCallingException('tool name contains illegal character, allowed: A-Z a-z 0-9 _ - : ${name}')
            }
        }
    }

    /** `mcp__{alias}__{tool}`：非法字符先替换为 `_`，再整体校验（不截断） */
    public static func mcp(alias: String, tool: String): String {
        let name = 'mcp__${sanitize(alias)}__${sanitize(tool)}'
        validate(name)
        name
    }

    static func sanitize(text: String): String {
        let builder = StringBuilder()
        for(rune in text.runes()){
            let legal = (rune >= r'a' && rune <= r'z') ||
                        (rune >= r'A' && rune <= r'Z') ||
                        (rune >= r'0' && rune <= r'9') ||
                        rune == r'_' || rune == r'-'
            if(legal){
                builder.append(rune)
            }else{
                builder.append('_')
            }
        }
        builder.toString()
    }
}

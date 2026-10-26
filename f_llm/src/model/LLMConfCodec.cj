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
package fountain::f_llm.model

import std.collection.HashMap
import fountain::f_data.*

/**
 * llm_conf.conf 列 <-> HashMap 的唯一入口。
 *
 * 写库前用 toColumn 把 Map 转成 JSON 文本作为 SQL 参数；读回后用 fromColumn 还原。
 */
public struct LLMConfCodec {
    private init(){}

    /** 写库前：Map -> JSON 字符串 */
    public static func toColumn(conf: HashMap<String, String>): String {
        toJson(conf)
    }

    /** 读库后：JSON 字符串 -> Map；空串或非法内容给空表，不让单条配置解析失败拖垮整次装载 */
    public static func fromColumn(text: String): HashMap<String, String> {
        let trimmed = text.trimAscii()
        if(trimmed.isEmpty() || !trimmed.startsWith('{')){
            return HashMap<String, String>()
        }
        if(let Some(conf) <- fromJson<HashMap<String, String>>(trimmed)){
            conf
        }else{
            HashMap<String, String>()
        }
    }
}

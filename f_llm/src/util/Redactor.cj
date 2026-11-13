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
package fountain::f_llm.util

import std.collection.{ArrayList, HashSet}

import fountain::f_data.*

/**
 * 凭据脱敏。
 *
 * 规则（评审 R9）：**前 4 + `****` + 后 4**；长度 ≤ 8 时整体掩码——
 * 短串露出前后各 4 位等于没脱敏。
 */
public struct Redactor {
    private init(){}

    public static func mask(secret: String): String {
        if(secret.size <= 8){
            return '****'
        }
        '${secret[0 .. 4]}****${secret[secret.size - 4 ..]}'
    }

    /** 默认敏感键：鉴权、密钥、口令三类 */
    public static func defaultKeys(): HashSet<String> {
        let keys = HashSet<String>()
        for(key in ['auth', 'authorization', 'apiKey', 'api_key', 'token', 'secret', 'password']){
            keys.add(key)
        }
        keys
    }

    /** 递归把敏感键（不区分大小写）的值换成掩码；只处理字符串值 */
    public static func redactJson(value: JsonValue, keys!: HashSet<String> = defaultKeys()): JsonValue {
        match(value){
            case obj: JsonObject =>
                let cleaned = JsonObject()
                for((key, item) in obj){
                    if(keys.contains(key) || keys.contains(key.toAsciiLower())){
                        match(item){
                            case text: JsonString => cleaned.add(key, mask(text.value))
                            case _ => cleaned.add(key, '****')
                        }
                    }else{
                        cleaned.add(key, redactJson(item, keys: keys))
                    }
                }
                cleaned
            case array: JsonArray =>
                let list = ArrayList<JsonValue>()
                for(item in array){
                    list.add(redactJson(item, keys: keys))
                }
                JsonArray(list: list)
            case other => other
        }
    }
}

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
package fountain::f_llm.llm

import std.sync.Mutex

import fountain::f_llm.config.*
import fountain::f_llm.service.*

/**
 * 全局配置快照的持有者。
 *
 * 懒建：第一次访问才按 `llm_confSource` 建来源并装载，避免模块导入期就连数据库。
 * 测试用 `setHolder` 注入静态来源，生产不调用。
 */
public class LLMConfs {
    private static let mutex = Mutex()
    private static var current: ?LLMConfsHolder = None<LLMConfsHolder>

    private init(){}

    public static func setHolder(value: LLMConfsHolder): Unit {
        synchronized(mutex){
            current = Some(value)
        }
    }

    public static func isConfigured(): Bool {
        synchronized(mutex){
            current.isSome()
        }
    }

    public static func holder(): LLMConfsHolder {
        synchronized(mutex){
            if(let Some(existing) <- current){
                return existing
            }
            let created = LLMConfsHolder(source: createConfSource(LLMConfig.getConfSource()))
            current = Some(created)
            created
        }
    }
}

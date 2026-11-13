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

import fountain::f_llm.store.*

/** 记忆记录：把一段文本写进长期记忆，供后续检索 */
public class MemoryRecorderTask {
    private init() {
    }

    /**
     * @param kind 记忆类型（如 `fact` / `note`）
     * @return 记录 id
     */
    public static func record(gateway: LoomStoreGateway, userId: Int64, namespace: String,
                              title: String, text: String, kind!: String = 'note'): String {
        let payload = '{"userId":${userId},"namespace":${FlowPlan.jsonQuote(namespace)},'
            + '"title":${FlowPlan.jsonQuote(title)},'
            + '"content":${FlowPlan.jsonQuote(text)},'
            + '"kind":${FlowPlan.jsonQuote(kind)}}'
        gateway.call('memory', 'add', payload)
    }

    /** 一次记录 + 超时保护（定时任务里用） */
    public static func recordWithTimeout(gateway: LoomStoreGateway, userId: Int64,
                                         namespace: String, title: String, text: String,
                                         timeoutMs!: Int64 = 5000): String {
        LoomTimeout.call({ => record(gateway, userId, namespace, title, text) }, timeoutMs)
    }
}

/** 技能演进：把近期使用情况合并进技能正文，版本号 +1 */
public class SkillEvolutionTask {
    private init() {
    }

    /**
     * @param chat 单轮模型调用：`(prompt) -> String`，由装配方注入
     * @return `evolved: <title> v<版本>` 或可读错误
     */
    public static func evolve(chat: (String) -> String, store: SkillStore,
                              title: String, usage: String): String {
        if(title.trimAscii().isEmpty()){
            return 'skill evolution requires title'
        }
        var target: ?Skill = None
        for(item in store.list()){
            if(item.title == title){
                target = Some(item)
            }
        }
        let existing = match(target){
            case Some(value) => value
            case None => return 'skill not found: ${title}'
        }
        let prompt = '现有技能正文：\n${existing.details}\n\n近期使用情况：\n${usage}\n\n'
            + '把使用情况里可复用的经验合并进正文，输出新的正文，不要输出解释。'
        let evolved = chat(prompt)
        if(evolved.trimAscii().isEmpty()){
            return 'skill evolution returned empty content: ${title}'
        }
        let next = Skill(existing.id, existing.title, evolved, existing.functions,
                         version: existing.version + 1)
        store.upsert(next)
        'evolved: ${next.title} v${next.version}'
    }
}

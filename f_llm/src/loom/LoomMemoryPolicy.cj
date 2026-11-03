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

import fountain::f_data.*

/**
 * 流程结束后从临时上下文提炼记忆与经验的策略。
 *
 * - `enabled=false`：完全关闭（连临时上下文都不记）；
 * - `summarize=false`（默认）：规则提炼——原文摘要写记忆，执行概况写经验，不发额外模型请求；
 * - `summarize=true`：让模型读摘要，返回 `{"memory":"…","experience":"…"}`；
 *   解析失败时回落到规则提炼，不会因为模型胡说就丢数据。
 */
public class LoomMemoryPolicy {
    public let enabled: Bool
    public let userId: Int64
    public let namespace: String
    public let maxTurns: Int64
    public let summarize: Bool
    public let model: String

    public init(enabled!: Bool = true, userId!: Int64 = 0, namespace!: String = 'loom',
                maxTurns!: Int64 = 20, summarize!: Bool = false, model!: String = '') {
        this.enabled = enabled
        this.userId = userId
        this.namespace = namespace
        this.maxTurns = maxTurns
        this.summarize = summarize
        this.model = model
    }

    private static var current = LoomMemoryPolicy()

    public static func install(policy: LoomMemoryPolicy): Unit {
        current = policy
    }

    public static func reset(): Unit {
        current = LoomMemoryPolicy()
    }

    public static func effective(): LoomMemoryPolicy {
        current
    }
}

/** 从临时上下文提炼并写入记忆（`kind=note`）与经验（`kind=experience`） */
public class LoomMemoryExtractor {
    private init() {
    }

    /**
     * @param flowName 流程名，用于记录标题
     * @param turns 本次执行的模型交互快照
     * @param host 宿主；仅 `summarize=true` 时用它发一次总结请求
     * @return 写入条数（0~2）
     */
    public static func extract(flowName: String, turns: ArrayList<LlmTurn>,
                               host: LoomHost, policy: LoomMemoryPolicy): Int64 {
        if(turns.isEmpty()){
            return 0
        }
        let digest = digestOf(turns, policy.maxTurns)
        var memory = '流程 ${flowName} 的上下文摘要：\n${digest}'
        var experience = '流程 ${flowName} 执行了 ${turns.size} 次模型交互，'
            + '最后一次输出：\n${truncate(turns[turns.size - 1].output, 600)}'

        if(policy.summarize && !policy.model.isEmpty()){
            let prompt = '以下是流程「${flowName}」执行过程的模型交互摘要：\n${digest}\n\n'
                + '提炼两条内容，只输出 JSON：\n'
                + '{"memory":"这次任务用到了哪些事实与结论","experience":"下次可复用的做法或踩过的坑"}'
            let text = Planner.stripFence(host.callLlm(policy.model, '', prompt))
            let parsed = parse(text)
            memory = parsed[0]
            experience = parsed[1]
        }

        var written: Int64 = 0
        if(LoomMemoryExtractor.write(policy, memory, '流程 ${flowName} 记忆', 'note')){
            written++
        }
        if(LoomMemoryExtractor.write(policy, experience, '流程 ${flowName} 经验', 'experience')){
            written++
        }
        written
    }

    private static func write(policy: LoomMemoryPolicy, content: String,
                              title: String, kind: String): Bool {
        if(content.trimAscii().isEmpty()){
            return false
        }
        let payload = '{"userId":${policy.userId},'
            + '"namespace":${FlowPlan.jsonQuote(policy.namespace)},'
            + '"title":${FlowPlan.jsonQuote(title)},'
            + '"content":${FlowPlan.jsonQuote(content)},'
            + '"kind":${FlowPlan.jsonQuote(kind)}}'
        try{
            LoomHostApi.callStore('memory', 'add', payload)
            true
        }catch(error: Exception){
            // 存储未装配时不影响流程结果
            false
        }
    }

    private static func digestOf(turns: ArrayList<LlmTurn>, maxTurns: Int64): String {
        var text = ''
        let limit = if(maxTurns > 0 && Int64(turns.size) > maxTurns){
            Int64(turns.size) - maxTurns
        }else{
            0
        }
        var index = limit
        while(index < Int64(turns.size)){
            let turn = turns[index]
            text += '[${index + 1}] model=${turn.model}\n'
            if(!turn.system.isEmpty()){
                text += 'system: ${truncate(turn.system, 300)}\n'
            }
            text += 'input: ${truncate(turn.input, 400)}\n'
            text += 'output: ${truncate(turn.output, 400)}\n'
            index++
        }
        text
    }

    /** JSON 解析失败时返回空串，调用方回落到规则提炼 */
    private static func parse(text: String): Array<String> {
        let fallback = ['', '']
        let trimmed = text.trimAscii()
        if(!trimmed.startsWith('{')){
            return fallback
        }
        match(JsonValue.fromStr(trimmed) as JsonObject){
            case Some(json) =>
                let memory = fieldOf(json, 'memory')
                let experience = fieldOf(json, 'experience')
                if(memory.isEmpty() && experience.isEmpty()){
                    return fallback
                }
                [memory, experience]
            case None => fallback
        }
    }

    private static func fieldOf(json: JsonObject, key: String): String {
        match(json.get(key)){
            case Some(value) =>
                match(value as JsonString){
                    case Some(text) => text.value
                    case None => ''
                }
            case None => ''
        }
    }

    private static func truncate(text: String, limit: Int64): String {
        if(Int64(text.size) <= limit){
            return text
        }
        text[0..limit] + '…'
    }
}

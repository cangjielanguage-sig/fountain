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

/** 模型提议的新技能：标题 + 正文 + 自验样例 */
public class SkillDraft {
    public let title: String
    public let details: String
    /** 没有样例的技能无法通过 A/B 门禁，也就永远无法自我演进，所以要求至少一条 */
    public let samples: ArrayList<SkillSample>

    public init(title: String, details: String, samples: ArrayList<SkillSample>) {
        this.title = title
        this.details = details
        this.samples = samples
    }
}

/**
 * 给一簇经验起名并写正文。
 *
 * 名字和边界都需要判断，所以这一步交给模型；但**只在簇足够大时**才问，避免平白花钱。
 * 模型输出不合法（缺字段、空串、标题过长）一律返回 None——宁可不建，也不能往技能库里
 * 塞一个叫「未命名」的东西。
 */
public class SkillNamer {
    private static let MAX_TITLE = 24

    private init() {
    }

    public static func propose(chat: (String, String) -> String,
                               experiences: ArrayList<ExperienceItem>): ?SkillDraft {
        if(experiences.isEmpty()){
            return None
        }
        var usage = ''
        for(item in experiences){
            usage += '- ${item.content}\n'
        }
        let system = '根据同一主题的一组经验，归纳出一个可复用的技能。'
            + '只输出 JSON，不要解释：{"title":"技能标题（不超过 24 字）",'
            + '"details":"可直接复用的做法，分条列出",'
            + '"samples":[{"input":"典型输入","expect":"正确答案里必须出现的关键信息"}]}'
            + '；samples 至少给 1 条，用于以后做回归对比'
        let raw = try{
            chat(system, usage)
        }catch(error: Exception){
            ''
        }
        if(raw.trimAscii().isEmpty()){
            return None
        }
        let text = Planner.stripFence(raw)
        if(!text.startsWith('{')){
            return None
        }
        // 解析器对非法输入是抛异常而不是返回 None，必须自己接住
        let parsed = try{
            JsonValue.fromStr(text)
        }catch(error: Exception){
            return None
        }
        let json = match(parsed as JsonObject){
            case Some(value) => value
            case None => return None
        }
        let title = fieldOf(json, 'title').trimAscii()
        let details = fieldOf(json, 'details').trimAscii()
        if(title.isEmpty() || details.isEmpty()){
            return None
        }
        if(Int64(title.size) > MAX_TITLE){
            return None
        }
        let samples = samplesOf(json)
        if(samples.isEmpty()){
            // 没样例的新技能不能自我演进：宁可不建，也不建一个「只能用手写样例救活」的空壳
            return None
        }
        SkillDraft(title, details, samples)
    }

    private static func samplesOf(json: JsonObject): ArrayList<SkillSample> {
        let result = ArrayList<SkillSample>()
        let raw = match(json.get('samples')){
            case Some(value) => value
            case None => return result
        }
        match(raw as JsonArray){
            case Some(items) =>
                for(item in items){
                    match(item as JsonObject){
                        case Some(entry) =>
                            let input = fieldOf(entry, 'input').trimAscii()
                            let expect = fieldOf(entry, 'expect').trimAscii()
                            if(!input.isEmpty() && !expect.isEmpty()){
                                result.add(SkillSample(input, expect))
                            }
                        case None => ()
                    }
                }
            case None => ()
        }
        result
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
}

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

import fountain::f_llm.store.*

/** 技能样例：一段输入 + 输出里必须出现的关键信息 */
public class SkillSample {
    public let input: String
    public let expect: String

    public init(input: String, expect: String) {
        this.input = input
        this.expect = expect
    }
}

public class SkillGateResult {
    public let passed: Bool
    public let oldScore: Float64
    public let newScore: Float64
    public let reason: String

    public init(passed: Bool, oldScore: Float64, newScore: Float64, reason: String) {
        this.passed = passed
        this.oldScore = oldScore
        this.newScore = newScore
        this.reason = reason
    }
}

/**
 * 技能演进的门禁：新版正文必须「不比旧版差」才允许落库。
 *
 * 判定方式是最朴素的 A/B：同一批样例分别用旧版、新版技能跑一遍，命中率高的留下。
 * 平手时也放行（≥），因为新版往往还顺带修了表述；但**没有任何样例时不放行**——
 * 无据可依的演进不如不演进。
 */
public class SkillGate {
    private init() {
    }

    /**
     * @param chat `(system, user) -> 输出`，由装配方注入（通常是 `host.callLlm`）
     * @param minScore 新版的最低绝对命中率（防止「比烂版好一点」就落库）
     */
    public static func evaluate(chat: (String, String) -> String,
                                oldDetails: String, newDetails: String,
                                samples: ArrayList<SkillSample>,
                                minScore!: Float64 = 0.6): SkillGateResult {
        if(samples.isEmpty()){
            return SkillGateResult(false, 0.0f64, 0.0f64,
                'no samples: evolution rejected without evidence')
        }
        if(newDetails.trimAscii().isEmpty()){
            return SkillGateResult(false, 0.0f64, 0.0f64, 'new details is empty')
        }

        let oldScore = scoreOf(chat, oldDetails, samples)
        let newScore = scoreOf(chat, newDetails, samples)
        if(newScore < oldScore){
            return SkillGateResult(false, oldScore, newScore,
                'new version scores lower: ${newScore} < ${oldScore}')
        }
        if(newScore < minScore){
            return SkillGateResult(false, oldScore, newScore,
                'new version below minScore: ${newScore} < ${minScore}')
        }
        SkillGateResult(true, oldScore, newScore,
            'passed: ${newScore} >= ${oldScore}')
    }

    private static func scoreOf(chat: (String, String) -> String,
                                details: String, samples: ArrayList<SkillSample>): Float64 {
        let system = '按以下技能正文完成任务：\n${details}'
        var hits: Int64 = 0
        for(sample in samples){
            let output = try{
                chat(system, sample.input)
            }catch(error: Exception){
                ''
            }
            if(output.toAsciiLower().contains(sample.expect.toAsciiLower())){
                hits++
            }
        }
        Float64(hits) / Float64(samples.size)
    }
}

/** 从技能的 `functions` 字段取样例（技能包 `skill.json` 里的 `samples`） */
public class SkillSamples {
    private init() {
    }

    public static func of(skill: Skill): ArrayList<SkillSample> {
        let result = ArrayList<SkillSample>()
        let text = skill.functions.trimAscii()
        if(text.isEmpty() || !text.startsWith('{')){
            return result
        }
        let json = match(JsonValue.fromStr(text) as JsonObject){
            case Some(value) => value
            case None => return result
        }
        let samples = match(json.get('samples')){
            case Some(value) => value
            case None => return result
        }
        match(samples as JsonArray){
            case Some(items) =>
                for(item in items){
                    match(item as JsonObject){
                        case Some(entry) =>
                            let input = strOf(entry, 'input')
                            let expect = strOf(entry, 'expect')
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

    private static func strOf(json: JsonObject, key: String): String {
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

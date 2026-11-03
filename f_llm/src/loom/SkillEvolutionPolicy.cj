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

/** 是否该为某个技能跑一次演进 */
public class EvolutionDecision {
    public let shouldEvolve: Bool
    public let reason: String

    public init(shouldEvolve: Bool, reason: String) {
        this.shouldEvolve = shouldEvolve
        this.reason = reason
    }
}

/**
 * 演进触发策略：样本够、成功率达标、并且过了冷却期，才值得花一次模型调用。
 *
 * 冷却期分两档：上一次演进被 A/B 门禁拒掉时用**更长**的间隔——否则同一个技能会
 * 每天试一次、每天被拒，白烧 token 还刷屏。
 */
public class SkillEvolutionPolicy {
    public let minSamples: Int64
    public let minSuccessRate: Float64
    public let cooldownSeconds: Int64
    public let failedCooldownSeconds: Int64

    public init(minSamples!: Int64 = 3, minSuccessRate!: Float64 = 0.8f64,
                cooldownSeconds!: Int64 = 86400, failedCooldownSeconds!: Int64 = 172800) {
        this.minSamples = minSamples
        this.minSuccessRate = minSuccessRate
        this.cooldownSeconds = cooldownSeconds
        this.failedCooldownSeconds = failedCooldownSeconds
    }

    /**
     * @param successCount 归属到该技能的成功经验条数
     * @param failureCount 归属到该技能的失败经验条数
     * @param lastEvolvedAt 上次演进尝试的时间戳（秒）；0 表示从未演进
     * @param lastGatePassed 上次演进是否通过了 A/B 门禁
     * @param now 当前时间戳（秒）
     */
    public func decide(successCount: Int64, failureCount: Int64,
                       lastEvolvedAt: Int64, lastGatePassed: Bool,
                       now: Int64): EvolutionDecision {
        if(successCount < minSamples){
            return EvolutionDecision(false,
                'not enough successful samples: ${successCount} < ${minSamples}')
        }
        let total = successCount + failureCount
        if(total > 0){
            let rate = Float64(successCount) / Float64(total)
            if(rate < minSuccessRate){
                return EvolutionDecision(false,
                    'success rate too low: ${rate} < ${minSuccessRate}')
            }
        }
        if(lastEvolvedAt > 0){
            let elapsed = now - lastEvolvedAt
            let required = if(lastGatePassed){ cooldownSeconds }else{ failedCooldownSeconds }
            if(elapsed < required){
                return EvolutionDecision(false,
                    'cooldown: ${elapsed}s < ${required}s (last gate passed: ${lastGatePassed})')
            }
        }
        EvolutionDecision(true, 'ok')
    }
}

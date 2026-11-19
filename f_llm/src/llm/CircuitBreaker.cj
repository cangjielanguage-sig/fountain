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

import std.collection.{ArrayList, HashMap, HashSet}
import std.sync.Mutex
import std.time.MonoTime

import fountain::f_log.*

import fountain::f_llm.config.*

/**
 * 按 conf.id 的连续失败熔断。
 *
 * - 只统计**可重试**失败（连接、超时、429、5xx、流中断）；4xx 不计入；
 * - 达到阈值后在冷却期内不参与调度，到期自动恢复；
 * - 状态只保存内存，不动持久化配置；进程重启即清零。
 */
class BreakerState {
    var failures: Int64 = 0
    var openUntil: ?MonoTime = None<MonoTime>
}

public class CircuitBreaker {
    private static let log = LoggerFactory.getLogger<CircuitBreaker>()

    private let mutex = Mutex()
    private let states = HashMap<Int64, BreakerState>()
    private let threshold: Int64
    private let cooldown: Duration

    public init(
        threshold!: Int64 = LLMConfig.getFailureThreshold(),
        cooldown!: Duration = LLMConfig.getCooldownDuration()
    ){
        this.threshold = if(threshold > 0){ threshold } else { 5 }
        this.cooldown = if(cooldown > Duration.Zero){ cooldown } else { Duration.second * 60 }
    }

    public func isOpen(confId: Int64): Bool {
        synchronized(mutex){
            if(let Some(state) <- states.get(confId)){
                if(let Some(until) <- state.openUntil){
                    if(MonoTime.now() < until){
                        return true
                    }
                    // 冷却到期：清零复活
                    state.openUntil = None<MonoTime>
                    state.failures = 0
                }
            }
        }
        false
    }

    public func recordSuccess(confId: Int64): Unit {
        synchronized(mutex){
            states.remove(confId)
        }
    }

    /** 只对可重试失败调用；达阈值即临时下线 */
    public func recordRetryableFailure(confId: Int64): Unit {
        var opened = false
        var failures = 0
        synchronized(mutex){
            let state = if(let Some(exist) <- states.get(confId)){
                exist
            }else{
                let created = BreakerState()
                states[confId] = created
                created
            }
            state.failures++
            failures = state.failures
            if(state.failures >= threshold && state.openUntil.isNone()){
                state.openUntil = Some(MonoTime.now() + cooldown)
                opened = true
            }
        }
        if(opened){
            let id = confId
            let count = failures
            log.warn{'llm circuit opened: confId=${id}, failures=${count}, cooldown=${cooldown}'}
        }
    }

    /** 刷新后清理已不存在的 conf.id */
    public func cleanup(alive: HashSet<Int64>): Int64 {
        var removed = 0
        synchronized(mutex){
            let dead = ArrayList<Int64>()
            for((id, _) in states){
                if(!alive.contains(id)){
                    dead.add(id)
                }
            }
            for(id in dead){
                states.remove(id)
                removed++
            }
        }
        removed
    }

    /** 测试/观测：当前记录条数 */
    public func size(): Int64 {
        synchronized(mutex){
            states.size
        }
    }
}

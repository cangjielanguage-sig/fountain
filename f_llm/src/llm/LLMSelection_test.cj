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

import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*

import fountain::f_llm.model.po.*

@Test
public class LLMSelectionTest {

    @TestCase
    func testRoundRobinAlternates(): Unit {
        let confs = ArrayList<LLMConf>([
            mkConf(1, 'chat-pro', 1, 'deepseek'),
            mkConf(2, 'chat-pro', 1, 'zhipu')
        ])
        let holder = LLMConfsHolder(source: CountingSource(confs), algorithm: 'roundRobin')
        let a = holder.peekNext('chat-pro').getOrThrow()
        let b = holder.peekNext('chat-pro').getOrThrow()
        let c = holder.peekNext('chat-pro').getOrThrow()
        @Expect(a.id != b.id, true)
        @Expect(b.id != c.id, true)
    }

    @TestCase
    func testRandomWeightRespectsRatio(): Unit {
        let confs = ArrayList<LLMConf>([
            mkConf(1, 'chat-pro', 3, 'deepseek'),
            mkConf(2, 'chat-pro', 1, 'zhipu')
        ])
        let holder = LLMConfsHolder(source: CountingSource(confs), algorithm: 'randomWeight')
        var first = 0
        var second = 0
        for(_ in 0 .. 400){
            let picked = holder.peekNext('chat-pro').getOrThrow()
            if(picked.id == 1){ first++ }else{ second++ }
        }
        @Expect(first > 0 && second > 0, true)
        let ratio = Float64(first) / Float64(second)
        @Expect(ratio > 2.0f64 && ratio < 4.5f64, true)
    }

    @TestCase
    func testOpenCircuitIsSkipped(): Unit {
        let confs = ArrayList<LLMConf>([
            mkConf(1, 'chat-pro', 100, 'deepseek'),
            mkConf(2, 'chat-pro', 1, 'zhipu')
        ])
        let breaker = CircuitBreaker(threshold: 1, cooldown: Duration.second * 30)
        breaker.recordRetryableFailure(1)
        let holder = LLMConfsHolder(source: CountingSource(confs), breaker: breaker, algorithm: 'randomWeight')
        for(_ in 0 .. 20){
            @Expect(holder.peekNext('chat-pro').getOrThrow().id, 2)
        }
    }

    @TestCase
    func testAllOpenReturnsNone(): Unit {
        let confs = ArrayList<LLMConf>([mkConf(1, 'chat-pro', 1, 'deepseek')])
        let breaker = CircuitBreaker(threshold: 1, cooldown: Duration.second * 30)
        breaker.recordRetryableFailure(1)
        let holder = LLMConfsHolder(source: CountingSource(confs), breaker: breaker)
        @Expect(holder.peekNext('chat-pro').isNone(), true)
    }

    @TestCase
    func testZeroWeightNeverPicked(): Unit {
        let confs = ArrayList<LLMConf>([
            mkConf(1, 'chat-pro', 0, 'deepseek'),
            mkConf(2, 'chat-pro', 1, 'zhipu')
        ])
        let holder = LLMConfsHolder(source: CountingSource(confs), algorithm: 'randomWeight')
        for(_ in 0 .. 20){
            @Expect(holder.peekNext('chat-pro').getOrThrow().id, 2)
        }
    }
}

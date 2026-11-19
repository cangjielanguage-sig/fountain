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
import std.time.MonoTime
import std.unittest.*
import std.unittest.testmacro.*

import fountain::f_llm.model.po.*
import fountain::f_llm.service.*

func busyWait(d: Duration): Unit {
    let start = MonoTime.now()
    while(MonoTime.now() - start < d){}
}

func mkConf(id: Int64, llmName: String, weight: Int64, provider: String): LLMConf {
    let c = LLMConf()
    c.id = id
    c.provider = provider
    c.llmName = llmName
    c.actualLlmName = 'deepseek-chat'
    c.url = 'https://api.deepseek.com'
    c.auth = 'sk'
    c.weight = weight
    c
}

class CountingSource <: LLMConfSource {
    CountingSource(private let confs: ArrayList<LLMConf>){}
    var calls: Int64 = 0
    var fail: Bool = false
    public prop name: String {
        get() {
            'counting'
        }
    }
    public func load(): ArrayList<LLMConf> {
        calls++
        if(fail){
            throw Exception('boom')
        }
        let copy = ArrayList<LLMConf>()
        copy.add(all: confs)
        copy
    }
}

@Test
public class LLMConfsHolderTest {

    @TestCase
    func testLoadsOnceWithinInterval(): Unit {
        let confs = ArrayList<LLMConf>([mkConf(1, 'chat-pro', 1, 'deepseek')])
        let source = CountingSource(confs)
        let holder = LLMConfsHolder(source: source)
        for(_ in 0 .. 5){
            holder.ensureFresh()
        }
        @Expect(source.calls, 1)
        @Expect(holder.version, 1)
    }

    @TestCase
    func testReloadAfterInterval(): Unit {
        let confs = ArrayList<LLMConf>([mkConf(1, 'chat-pro', 1, 'deepseek')])
        let source = CountingSource(confs)
        let holder = LLMConfsHolder(source: source, refreshInterval: Duration.millisecond * 20)
        holder.ensureFresh()
        busyWait(Duration.millisecond * 40)
        holder.ensureFresh()
        @Expect(source.calls, 2)
        @Expect(holder.version, 2)
    }

    @TestCase
    func testFailureKeepsOldSnapshot(): Unit {
        let confs = ArrayList<LLMConf>([mkConf(1, 'chat-pro', 1, 'deepseek')])
        let source = CountingSource(confs)
        let holder = LLMConfsHolder(source: source, refreshInterval: Duration.millisecond * 20)
        holder.ensureFresh()
        source.fail = true
        busyWait(Duration.millisecond * 40)
        holder.ensureFresh()
        @Expect(holder.version, 1)
        @Expect(holder.all().size, 1)
    }

    @TestCase
    func testCandidatesByNameAndPlaceholderDropped(): Unit {
        let broken = mkConf(3, 'chat-pro', 1, 'deepseek')
        broken.url = ''
        let confs = ArrayList<LLMConf>([
            mkConf(1, 'chat-pro', 3, 'deepseek'),
            mkConf(2, 'chat-pro', 1, 'zhipu'),
            broken,
            mkConf(4, 'chat-mini', 1, 'deepseek')
        ])
        let holder = LLMConfsHolder(source: CountingSource(confs))
        @Expect(holder.candidates('chat-pro').size, 2)
        @Expect(holder.all().size, 3)
        @Expect(holder.candidates('nope').size, 0)
    }
}

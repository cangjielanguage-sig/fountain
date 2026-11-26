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
package fountain::f_llm.embedding

import std.collection.{ArrayList, HashMap}
import std.unittest.*
import std.unittest.testmacro.*

import fountain::f_llm.llm.*
import fountain::f_llm.model.po.*
import fountain::f_llm.service.*

let EMBED_RESP = '{"data":[{"embedding":[0.1,0.2,0.3],"index":0}],"usage":{"prompt_tokens":4,"total_tokens":4}}'

class EmbedSource <: LLMConfSource {
    private let confs: ArrayList<LLMConf>

    EmbedSource(confs: ArrayList<LLMConf>) {
        this.confs = confs
    }

    public prop name: String {
        get() {
            'static'
        }
    }

    public func load(): ArrayList<LLMConf> {
        confs
    }
}

class EmbedTransport <: LLMTransport {
    EmbedTransport(private let statuses: ArrayList<Int64>){}
    var calls: Int64 = 0
    var lastUrl: String = ''
    var lastBody: String = ''
    public func post(url: String, headers: HashMap<String, String>, body: String): LLMHttpResponse {
        let index = calls
        calls++
        lastUrl = url
        lastBody = body
        let status = if(index < statuses.size){ statuses[index] }else{ statuses[statuses.size - 1] }
        LLMHttpResponse(status, EMBED_RESP)
    }
}

func embedConf(id: Int64, llmName: String): LLMConf {
    let conf = LLMConf()
    conf.id = id
    conf.provider = 'zhipu'
    conf.llmName = llmName
    conf.actualLlmName = 'embedding-3'
    conf.url = 'https://api.example/v1'
    conf.auth = 'sk-test'
    conf.setConf(HashMap<String, String>([('llmType', 'embedding')]))
    conf
}

func embedHolder(confs: ArrayList<LLMConf>): LLMConfsHolder {
    LLMConfsHolder(source: EmbedSource(confs), refreshInterval: Duration.second * 3600)
}

@Test
public class EmbeddingTest {

    @TestCase
    func testEmbedSuccess(): Unit {
        LLMConfs.setHolder(embedHolder(ArrayList<LLMConf>([embedConf(601, 'embed-pro')])))
        let transport = EmbedTransport(ArrayList<Int64>([200]))
        Embedding.setTransport(transport)
        let params = EmbeddingParam(agentId: 1, session: 's', input: '仓颉编程语言')
        let response = Embedding.embed('embed-pro', params)
        @Expect(response.embedding.size, 3)
        @Expect(response.embedding[2], 0.3f64)
        @Expect(response.usage.total, 4)
        @Expect(transport.lastUrl, 'https://api.example/v1/embeddings')
        @Expect(transport.lastBody.contains('"model":"embedding-3"'), true)
        @Expect(transport.lastBody.contains('仓颉编程语言'), true)
    }

    @TestCase
    func testEmbedFallsBackByModelName(): Unit {
        // 兼容旧调用方：第一个参数给的是模型名而不是 llmName
        LLMConfs.setHolder(embedHolder(ArrayList<LLMConf>([embedConf(602, 'embed-pro')])))
        let transport = EmbedTransport(ArrayList<Int64>([200]))
        Embedding.setTransport(transport)
        let response = Embedding.embed('embedding-3', EmbeddingParam(agentId: 1, session: 's', input: 'x'))
        @Expect(response.embedding.size, 3)
    }

    @TestCase
    func testEmbedFailover(): Unit {
        LLMConfs.setHolder(embedHolder(ArrayList<LLMConf>([
            embedConf(611, 'embed-retry'),
            embedConf(612, 'embed-retry')
        ])))
        let transport = EmbedTransport(ArrayList<Int64>([429, 200]))
        Embedding.setTransport(transport)
        let response = Embedding.embed('embed-retry', EmbeddingParam(agentId: 1, session: 's', input: 'x'))
        @Expect(transport.calls, 2)
        @Expect(response.usage.llmId, 612)
    }

    @TestCase
    func testEmbedNoConfThrows(): Unit {
        LLMConfs.setHolder(embedHolder(ArrayList<LLMConf>()))
        var message = ''
        try{
            Embedding.embed('none', EmbeddingParam(agentId: 1, session: 's', input: 'x'))
        }catch(e: EmbeddingException){
            message = e.message
        }
        @Expect(message.contains('no embedding conf'), true)
    }

    @TestCase
    func testParseRejectsEmptyVector(): Unit {
        var thrown = false
        try{
            Embedding.parse('{"data":[]}')
        }catch(_: EmbeddingException){
            thrown = true
        }
        @Expect(thrown, true)
    }
}

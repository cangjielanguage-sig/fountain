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
package fountain::fcoder.model.entity

public class KnowledgeEntity {
    public KnowledgeEntity(
        private let content!: String, 
        private let kind!: Array<KnowledgeKind>, 
        private let size!: Int64,
        private let searchExecutor!: (KnowledgeParam, Array<Float64>) -> ArrayList<String>,
        private let llmAccessor!: (LLMType, LLMParams) -> LLMResp,
        private let embeddingAccessor!: (ModelName, String, Int64) -> EmbeddingResp,
        private let usageSaver!: (TokenUsage) -> Unit
    ){
        params = extractKeywords(content, kind, size, llmAccessor, usageSaver)
        let embeddingResp = embeddingAccessor(MODEL_NAME_GLM_EMBEDDING3, params.content, 1024)
        keywordsEmbedding = embeddingResp.embedding
        usageSaver(embeddingResp.usage)
        list = searchExecutor(params, keywordsEmbedding)
    }

    private static func extractKeywords(content: String, kind: Array<KnowledgeKind>, size: Int64, llmAccessor: (LLMType, LLMParams) -> LLMResp, usageSaver: (TokenUsage) -> Unit): KnowledgeParam {
        let params = LLMParams()
        params.model = MODEL_NAME_GLM4_7_FLASH
        params.thinking.clear_thinking = true
        let messages = ArrayList<ChatMessage>()
        params.messages = messages
        let system = SystemMessage()
        system.content = '''
为指定的内容提取关键词，并以JSON格式返回。
## JSON格式
```json
{
    "keywords": [
        "关键词1",
        "关键词2",
        "关键词3"
    ],
    "weight": 0.7,
    "confidence": 0.8
}

### 响应JSON各字段的意义
|字段名|说明|是否必须|
|:----|:---|:------|
|keywords|关键词列表，每个关键词是一个字符串|
|weight|向量索引的权重，范围0到1的浮点数，默认是0.7，将keywords与本地知识库的向量距离和全文匹配查询，weight是向量距离的权重，(1 - weight)是全文匹配的权重|
|confidence|查询结果的置信度，范围0到1的浮点数，默认是0.8，用keywords在本地知识库查询到的文档的最低置信度，置信度高于这个值的文档才被采纳|
'''
        messages.add(system)
        let user = UserMessage()
        user.content = content
        messages.add(user)
        let llmResp = llmAccessor(LLM_TYPE_TEXT, params)
        usageSaver(llmResp.usage)
        let json = (llmResp.messages[0].content |> JsonValue.fromStr).asObject()
        let weight = json.get('weight')?.asFloat().getValue() ?? 0.7
        let confidence = json.get('confidence')?.asFloat().getValue() ?? 0.8
        let keywords = (json.get('keywords')?.asArray() ?? JsonArray()).getItems()
        let keytext = StringGenerator()
        for(keyword in keywords){
            if(keytext.size > 0){
                keytext.append(',')
            }
            keytext.append(keyword)
        }
        KnowledgeParam(
            content: keytext.toString(),
            kind: kind,
            size: size,
            weight: weight,
            confidence: confidence
        )
    }

    private let params: KnowledgeParam
    private let keywordsEmbedding: Array<Float64>
    private let list: ArrayList<String>
    private var conf: ?LLMConf = None
    private var remoteResults = None<ArrayList<SearchResult>>

    protected func queryConf(finder: (Array<LLMType>) -> ArrayList<LLMConf>): This {
        if(list.size < params.size){
            conf = finder([LLM_TYPE_SEARCH])[0]
        }
        this
    }
    protected func search(searcher!: (LLMConf, String) -> ArrayList<SearchResult>): This {
        if(list.size < params.size){
            remoteResults = searcher(conf.getOrThrow(), params.content)
        }
        this
    }
    protected func save(knowledgeSaver!: (Knowledge) -> Unit): ArrayList<String> {
        if(list.size == params.size){
            return list
        }
        let results = remoteResults.getOrThrow()
        for(result in results){
            let title = result.title
            let content = '''
            ${title}

            ${result.content}
            '''
            let resp = embeddingAccessor(MODEL_NAME_GLM_EMBEDDING3, content, 1024)
            let knowledge = Knowledge(
                kind: KNOWLEDGE_KIND_ARTICLE,
                md5: {=> 
                    let md5 = MD5()
                    content.unsafeBytes() |> md5.write
                    md5.finish() |> toHexString
                }(),
                source: result.link,
                title: title,
                content: content,
                embedding: resp.embedding
            )
            let usage = resp.usage
            knowledgeSaver(knowledge)
            usageSaver(usage)
        }
        searchExecutor(params, keywordsEmbedding)
    }
}
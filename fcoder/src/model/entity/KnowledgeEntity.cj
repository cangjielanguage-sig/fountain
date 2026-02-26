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
        private let param: KnowledgeParam,
        private let searchExecutor!: (KnowledgeParam, Array<Float64>) -> ArrayList<String>,
        private let llmAccessor!: (LLMType, LLMParams) -> LLMResp,
        private let embeddingAccessor!: (ModelName, String, Int64) -> EmbeddingResp,
        private let usageSaver!: (TokenUsage) -> Unit
    ){
        keywords = extractKeywords(param.content, llmAccessor, usageSaver)
        let embeddingResp = embeddingAccessor(MODEL_NAME_GLM_EMBEDDING3, keywords, 1024)
        keywordsEmbedding = embeddingResp.embedding
        usageSaver(embeddingResp.usage)
        param.content = keywords
        list = searchExecutor(param, keywordsEmbedding)
    }

    private static func extractKeywords(content: String, llmAccessor: (LLMType, LLMParams) -> LLMResp, usageSaver: (TokenUsage) -> Unit){
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
    ]
}
'''
        messages.add(system)
        let user = UserMessage()
        user.content = content
        messages.add(user)
        let llmResp = llmAccessor(LLM_TYPE_TEXT, params)
        usageSaver(llmResp.usage)
        let json = llmResp.messages[0].content
        let start = json.indexOf('[').getOrThrow()
        let end = json.lastIndexOf(']').getOrThrow()
        json[start + 1 .. end].replace('"', '').trimAscii()
    }

    private let keywords: String
    private let keywordsEmbedding: Array<Float64>
    private let list: ArrayList<String>
    private var conf: ?LLMConf = None
    private var remoteResults = None<ArrayList<SearchResult>>

    protected func queryConf(finder: (Array<LLMType>) -> ArrayList<LLMConf>): This {
        if(list.size < param.size){
            conf = finder([LLM_TYPE_SEARCH])[0]
        }
        this
    }
    protected func search(searcher!: (LLMConf, String) -> ArrayList<SearchResult>): This {
        if(list.size < param.size){
            remoteResults = searcher(conf.getOrThrow(), param.content)
        }
        this
    }
    protected func save(knowledgeSaver!: (Knowledge) -> Unit): ArrayList<String> {
        if(list.size == param.size){
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
        searchExecutor(param, keywordsEmbedding)
    }
}
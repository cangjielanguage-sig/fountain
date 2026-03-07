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
package fountain::f_llm.model.entity

public class KnowledgeEntity {
    public KnowledgeEntity(
        private let params: KnowledgeParam,
        private let searchExecutor!: (KnowledgeParam, Array<Float64>) -> ArrayList<String>,
        private let embeddingAccessor!: (ModelName, String, Int64) -> EmbeddingResp,
        private let usageSaver!: (TokenUsage) -> Unit
    ){
        let embeddingResp = embeddingAccessor(MODEL_NAME_GLM_EMBEDDING3, params.keywords, 1024)
        keywordsEmbedding = embeddingResp.embedding
        usageSaver(embeddingResp.usage)
        list = searchExecutor(params, keywordsEmbedding)
    }

    private let keywordsEmbedding: Array<Float64>
    private let list: ArrayList<String>
    private var conf: ?LLMConf = None
    private var remoteResults = None<ArrayList<SearchResult>>

    public func queryConf(finder: (Array<LLMType>) -> ArrayList<LLMConf>): This {
        if(list.size < params.maxResults){
            conf = finder([LLM_TYPE_SEARCH])[0]
        }
        this
    }
    public func search(searcher!: (String) -> ArrayList<SearchResult>): This {
        if(list.size < params.maxResults){
            remoteResults = searcher(params.keywords)
        }
        this
    }
    public func save(knowledgeSaver!: (Knowledge) -> Unit): ArrayList<String> {
        if(list.size == params.maxResults){
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
            usage.agentId = params.agentId
            usage.skillId = params.skillId
            knowledgeSaver(knowledge)
            usageSaver(usage)
        }
        searchExecutor(params, keywordsEmbedding)
    }
}
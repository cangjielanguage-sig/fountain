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
        private let searchExecutor: (KnowledgeParam) -> ArrayList<String>
    ){}

    private var conf: ?LLMConf = None

    protected func search(): This {
        if(let list <- searchExecutor(param) && list.size == param.size){
            perform BaseCommand<ArrayList<String>, Unit>(list)
        }
        this
    }
    protected func queryConf(finder: (Array<LLMType>) -> ArrayList<LLMConf>): This {
        conf = finder([LLM_TYPE_SEARCH])[0]
        this
    }
    protected func search(
        searcher!: (LLMConf, String) -> ArrayList<SearchResult>,
        embeddingAccessor!: (ModelName, String, Int64) -> EmbeddingResp,
        knowledgeSaver!: (Knowledge) -> Unit,
        usageSaver!: (TokenUsage) -> Unit): Unit {
        let results = searcher(conf.getOrThrow(), param.content)
        for(result in results){ 
            let url = result.link
            let title = result.title
            let content = '''
            ${title}

            ${result.content}
            '''
            let resp = embeddingAccessor(MODEL_NAME_GLM_EMBEDDING3, content, 1024)
            let embedding = resp.embedding
            let knowledge = Knowledge(
                kind: KNOWLEDGE_KIND_ARTICLE,
                md5: {=> 
                    let md5 = MD5()
                    content.unsafeBytes() |> md5.write
                    md5.finish() |> toHexString
                }(),
                source: url,
                title: title,
                content: content,
                embedding: embedding
            )
            let usage = resp.usage
            knowledgeSaver(knowledge)
            usageSaver(usage)
        }
        perform BaseCommand<ArrayList<String>, Unit>(searchExecutor(param))
    }
}
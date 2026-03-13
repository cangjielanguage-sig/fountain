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

import fountain::f_data

public class GLMEmbeddingContext <: AbstractEmbeddingContext {
    private static let log = LoggerFactory.getLogger<GLMEmbeddingContext>()
    public init(conf: LLMConf){
        super(conf)
    }
    public func access(param: EmbeddingParam): EmbeddingResp {
        http(url, conf){http => 
            let start = MonoTime.now()
            let params = JsonObject()
            try{
                params.put('model', JsonString(name))
                params.put('input', JsonString(param.input))
                params.put('dimensions', JsonInt(param.dimension))
                let respJson = http.post(params.toString()).readJson().asObject()
                let embeddingJson = respJson.get('data')?.asArray()[0].asObject().get('embedding')?.asArray() ?? JsonArray()
                let usageJson = respJson.get('usage').getOrThrow().asObject()
                let resp = EmbeddingResp()
                resp.embedding = f_data.convert<Array<Float64>>(embeddingJson.toData()) ?? []
                let usage = resp.usage
                usage.llmId = super.id
                usage.agentId = param.agentId
                DataObject<TokenUsage>.populate(usageJson.toData(), usage)
                resp
            }catch(e: Exception){
                log.error(e){'embedding error ${params}'}
                throw e
            }finally{
                log.info{'embedding model: ${name}, agent: ${param.agentId}, elapsed: ${MonoTime.now() - start}'}
            }
        }
    }
}
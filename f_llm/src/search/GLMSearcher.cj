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
package fountain::f_llm.search

import fountain::f_data

public class GLMSearcher <: AbstractSearcher {
    private static let log = LoggerFactory.getLogger<GLMSearcher>()
    private let engine: String
    public init(conf: LLMConf){
        super(conf)
        this.engine = super.name[4 ..]
    }
    public func search(keywords: String, count: Int64): ArrayList<SearchResult> {
        resource(http(url, conf)){http =>//'https://open.bigmodel.cn/api/paas/v4/web_search'
            let params = SearchParams()
            try{
                params.searchQuery = keywords
                params.searchEngine = engine
                params.count = count
                let json = http.post('application/json', params).readJson().asObject()
                let results = json.get('search_result')?.asArray().toData()
                if(let Some(array) <- results){
                    f_data.convert<ArrayList<SearchResult>>(array).getOrThrow()
                }else{
                    ArrayList<SearchResult>()
                }
            }catch(e: Exception){
                let requestId = params.requestId
                log.error(e){'search failed, requestId: ${requestId}'}
                throw e
            }
        }
    }
}
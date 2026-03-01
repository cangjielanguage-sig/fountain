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
import fountain::f_data.macros.*

@DataAssist[props fields]
public class SearchResult {
    private var title: String = ''
    private var content: String = ''
    private var link: String = ''
    private var media: String = ''
    private var icon: String = ''
    private var refer: String = ''
    private var publish_date: String = ''
}

@DataAssist[props fields]
public class SearchParams {
    @FieldAlias['search_query']
    private var searchQuery: String = ''
    @FieldAlias['search_engine']
    private var searchEngine: String = 'search_pro'
    private var count: Int64 = 50
    @FieldAlias['content_size']
    private let contentSize: String = CONTENT_SIZE_HIGH
    @FieldAlias['request_id']
    private let requestId: String = UUID.random().toString()
    @FieldAlias['user_id']
    private let userId: String = FCODER_USER
}

public abstract class AbstractSearcher {
    public AbstractSearcher(
        protected let url!: String, 
        protected let name!: String,
        protected let conf!: String
    ){}
    public init(conf: LLMConf){
        this(url: conf.url, name: conf.name, conf: conf.conf)
    }
    public func search(keywords: String, count: Int64): ArrayList<SearchResult>
}
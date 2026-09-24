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

import std.sync.Mutex

import fountain::f_bean.lookup

public class SearchMediator {
    private static let contextCreators = HashMap<String, (LLMConf) -> AbstractSearcher>()
    
    static init(){
        let creator = {conf: LLMConf => GLMSearcher(conf)}
        register('glm-search_std', creator)
        register('glm-search_pro', creator)
        register('glm-search_pro_sogou', creator)
        register('glm-search_pro_quark', creator)
    }
    public static func register(engine: String, creator: (LLMConf) -> AbstractSearcher){
        contextCreators['${engine}+${LLM_TYPE_SEARCH}'] = creator
    }
    private let contexts = ConcurrentHashMap<String, AbstractSearcher>()
    private init(){}

    private static let instance_ = SearchMediator()
    public static prop instance: SearchMediator {
        get(){
            instance_
        }
    }

    private let mutex = Mutex()
    private func load(key: String){
        if(let Some(x) <- contexts.get(key)){
            return x
        }
        synchronized(mutex){
            if(let Some(x) <- contexts.get(key)){
                return x
            }
            for(conf in lookup<LLMFinder>().listConfs([LLM_TYPE_SEARCH])){
                let key = '${conf.name}+${conf.llmType}'
                if(let Some(newer) <- contextCreators.get(key)){
                    contexts[key] = newer(conf)
                }
            }
            return contexts[key]
        }
    }
    public func search(engine: String, keywords: String, count: Int64): ArrayList<SearchResult> {
        let key = '${engine}+${LLM_TYPE_SEARCH}'
        load(key).search(keywords, count)
    }
}
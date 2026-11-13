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
package fountain::f_llm.service

import std.collection.*

import fountain::f_llm.model.po.*
import fountain::f_llm.store.*

/**
 * 以 `MetaStore.confs` 为数据源的配置来源（1.3）。
 *
 * 与 `DatabaseConfSource` 的区别：不直接碰 DAO/执行器，PG/MySQL/f_store 由
 * `MetaStoreAdapter` 按 `llm_metaStore` 决定。
 */
public class StoreMetaConfSource <: LLMConfSource {
    private let meta: MetaStore

    public init(meta: MetaStore) {
        this.meta = meta
    }

    public prop name: String {
        get() {
            'store'
        }
    }

    public func load(): ArrayList<LLMConf> {
        let result = ArrayList<LLMConf>()
        var seq: Int64 = 0
        for(llmName in meta.confs.names()){
            for(view in meta.confs.candidates(llmName)){
                seq++
                let conf = LLMConf()
                conf.id = seq
                conf.provider = view.provider
                conf.llmName = view.llmName
                conf.actualLlmName = view.actualLlmName
                conf.url = view.llmUrl
                conf.auth = view.auth
                conf.temperature = view.temperature
                conf.alwaysThinking = view.alwaysThinking
                conf.enabled = view.enabled
                conf.weight = view.weight
                result.add(conf)
            }
        }
        result
    }
}

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
package fountain::f_llm.store

import fountain::f_bean.*

/**
 * `MetaStore` 适配器：业务层只依赖本类。
 *
 * 具体实现由 `f_bean` 依据 `llm_metaStore` 选定；没有匹配时回退到 f_store
 * （元数据族的无库默认实现）。
 */
public class MetaStoreAdapter <: MetaStore {
    private let delegate: MetaStore

    public init() {
        this.delegate = lookupOption<MetaStore>() ?? FStoreMetaStore(StoreSettings.load().metaStorePath)
    }

    public prop characters: CharacterStore {
        get() { delegate.characters }
    }

    public prop skills: SkillStore {
        get() { delegate.skills }
    }

    public prop prompts: PromptStore {
        get() { delegate.prompts }
    }

    public prop confs: LLMConfStore {
        get() { delegate.confs }
    }
}

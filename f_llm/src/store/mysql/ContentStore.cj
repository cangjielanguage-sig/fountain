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
package fountain::f_llm.store.mysql

import fountain::f_llm.store.*

/** MySQL 内容族：记忆 + 知识文档（4.x）。 */
public class MySqlContentStore <: ContentStore {
    private let knowledgeStore = MySqlKnowledgeStore()
    private var cachedMemory: ?MemoryStore = None

    public init() {
    }

    public prop memory: MemoryStore {
        get() {
            match(cachedMemory){
                case Some(store) => store
                case None =>
                    let store = SqlMemoryStore()
                    cachedMemory = Some(store)
                    store
            }
        }
    }

    public prop knowledge: KnowledgeStore {
        get() { knowledgeStore }
    }
}

let _mysqlContentRegistered = Stores.registerContent('mysql', { => MySqlContentStore() })

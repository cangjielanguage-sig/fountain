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
package fountain::f_llm.loom

import fountain::f_llm.store.*
import fountain::f_llm.store.mysql.MySqlEvolutionStateStore
import fountain::f_llm.store.postgres.PostgresEvolutionStateStore

/**
 * 演进状态存储的实现选择：跟随 `llm_metaStore`，默认 `f_store`。
 *
 * 放在 loom 包避免 `store` 反向依赖 `store.postgres` / `store.mysql`。
 */
public class EvolutionStateStores {
    private init() {
    }

    public static func byName(name: String): EvolutionStateStore {
        match(name.trimAscii().toAsciiLower()){
            case 'postgres' => PostgresEvolutionStateStore()
            case 'mysql' => MySqlEvolutionStateStore()
            case 'memory' => InMemoryEvolutionStateStore()
            case _ => FStoreEvolutionStateStore()
        }
    }

    public static func current(): EvolutionStateStore {
        byName(StoreSettings.load().metaStore)
    }

    /** 启动准备：SQL 部署建表；失败不阻断（首次读写还会再试） */
    public static func bootstrap(): Unit {
        try{
            current().ensureSchema()
        }catch(error: Exception){
            ()
        }
    }
}

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
import fountain::f_llm.store.mysql.MySqlEvolutionStore
import fountain::f_llm.store.postgres.PostgresEvolutionStore

/**
 * 演进报告表的实现选择：跟随 `llm_metaStore`（与元数据族同一份部署配置）。
 *
 * 放在 loom 包而不是 store 包，是为了避免 `store` 反向依赖 `store.postgres` / `store.mysql`
 * 形成循环——那两个包本身要 import `store`。
 */
public class EvolutionStores {
    private init() {
    }

    public static func byName(name: String): EvolutionStore {
        match(name.trimAscii().toAsciiLower()){
            case 'postgres' => PostgresEvolutionStore()
            case 'mysql' => MySqlEvolutionStore()
            case 'memory' => InMemoryEvolutionStore()
            case _ => FStoreEvolutionStore()
        }
    }

    public static func current(): EvolutionStore {
        byName(StoreSettings.load().metaStore)
    }

    /**
     * 启动时准备：选用 mysql/postgres 时先检查表与索引，没有就建。
     *
     * 失败不阻断启动——数据库可能比应用晚就绪，首次写入还会再试一次；
     * 把「建表失败」变成启动失败，会让一次数据库抖动拖垮整个进程。
     */
    public static func bootstrap(): Unit {
        try{
            current().ensureSchema()
        }catch(error: Exception){
            ()
        }
    }
}

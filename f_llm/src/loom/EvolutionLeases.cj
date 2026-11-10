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

import std.time.DateTime

import fountain::f_llm.store.*
import fountain::f_llm.store.hydra.HydraEvolutionLease
import fountain::f_llm.store.mysql.MySqlEvolutionLease
import fountain::f_llm.store.postgres.PostgresEvolutionLease

/**
 * 演进租约的实现选择：跟着**向量存储**走（`llm_memoryStore`）。
 *
 * | 配置 | 实现 | 互斥方式 |
 * |---|---|---|
 * | `mysql` / `postgres` | 单行表 + 条件更新 | 真正的 CAS |
 * | `f_hydra` | 本地向量记录（全 0 向量） | 单进程本地存储，无需跨进程 |
 * | `fhydra` | 远程向量记录（全 0 向量） | 先写后读校验 |
 * | 其它（memory 等） | f_store / 内存 | 单进程 |
 */
public class EvolutionLeases {
    private init() {
    }

    public static func byName(name: String): EvolutionLease {
        match(name.trimAscii().toAsciiLower()){
            case 'postgres' => PostgresEvolutionLease()
            case 'mysql' => MySqlEvolutionLease()
            case 'f_hydra' => HydraEvolutionLease()
            case 'fhydra' => HydraEvolutionLease.remote()
            case 'memory' => InMemoryEvolutionLease()
            case _ => FStoreEvolutionLease()
        }
    }

    public static func current(): EvolutionLease {
        byName(StoreSettings.load().memoryStore)
    }

    /**
     * 启动准备：建表（SQL 实现）+ 确保租约值存在。
     *
     * 失败不阻断启动——记忆/演进都不是「起不来就不能用」的强依赖。
     */
    public static func bootstrap(): String {
        let box = LeaseTextBox()
        try{
            let lease = current()
            lease.ensureSchema()
            box.value = lease.ensure(DateTime.now().toUnixTimeStamp().toSeconds())
        }catch(error: Exception){
            ()
        }
        box.value
    }
}

class LeaseTextBox {
    public var value: String = ''
}

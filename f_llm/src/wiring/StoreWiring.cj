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
package fountain::f_llm.wiring

import std.sync.*

import fountain::f_llm.store.*

import fountain::f_llm.store.mysql.*
import fountain::f_llm.store.postgres.*

/**
 * 存储接线（P0）：把实现包与 `Stores` 注册表接上，并做启动校验。
 *
 * 两个实现包的 `ContentStore` 文件里有顶层自注册，**只有包被加载时才会执行**。
 * 业务侧（`Memory`）通过本包 import 它们，从而保证注册表非空；`wire()` 再做一次
 * 幂等兜底（应对 `Stores.resetForTest()` 之后的重建）。
 */
public class StoreWiring {
    private static let mutex = Mutex()

    private init() {
    }

    /**
     * 幂等接线：
     * 1. 补齐 `inMemory` / `postgres` / `mysql` 三个内容族工厂；
     * 2. 调用 `Stores.bootstrap()` 校验配置值，未知值立即抛错并列出可选实现。
     */
    public static func wire(): Unit {
        synchronized(mutex){
            ensure('inMemory', { => InMemoryContentStore() })
            ensure('postgres', { => PostgresContentStore() })
            ensure('mysql', { => MySqlContentStore() })
            Stores.bootstrap()
        }
    }

    private static func ensure(name: String, factory: () -> ContentStore): Unit {
        if(!Stores.containsContent(name)){
            Stores.registerContent(name, factory)
        }
    }
}

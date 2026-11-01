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

import fountain::f_bean.*
import fountain::f_log.*

import fountain::f_llm.store.*
import fountain::f_llm.store.hydra.*

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
    private static var kindsSeeded = false
    private static var beanInitialized = false

    private init() {
    }

    /**
     * 幂等接线：
     * 1. 补齐 `inMemory` / `postgres` / `mysql` 三个内容族工厂；
     * 2. 调用 `Stores.bootstrap()` 校验配置值，未知值立即抛错并列出可选实现。
     *
     * **配置只在首次调用时读取**：f_llm 永不支持运行期修改配置（`BeanFactory` 条件只评估一次、
     * 被丢弃的 bean 不可恢复），换实现/换端点必须重启进程。见 `doc/known-limitations.md` §0。
     */
    public static func wire(): Unit {
        synchronized(mutex){
            // bean 条件只在 afterRegistered() 里评估；不调用的话 lookupOption 会返回
            // 未按配置过滤的 bean。进程内只做一次（被丢弃的 bean 不可恢复）。
            if(!beanInitialized){
                BeanFactory.instance.afterRegistered()
                beanInitialized = true
            }
            ensure('inMemory', { => InMemoryContentStore() })
            ensure('postgres', { => PostgresContentStore() })
            ensure('mysql', { => MySqlContentStore() })
            ensure('f_hydra', { => HydraContentStore() })
            ensure('fhydra', { => FhydraContentStore() })
            ensureMeta('postgres', { => PostgresMetaStore() })
            ensureMeta('mysql', { => MySqlMetaStore() })
            ensureMeta('f_store', { => FStoreMetaStore(StoreSettings.load().metaStorePath) })
            Stores.bootstrap()
            seedKinds()
        }
    }

    /**
     * 预定义 kind 补种（P1）：数据库不可用时只告警，不阻断启动——
     * 权重表在代码里有默认值，缺表不影响读写。
     */
    private static func seedKinds(): Unit {
        if(kindsSeeded){
            return
        }
        try{
            match(StoreSettings.load().memoryStore){
                case 'postgres' =>
                    let persistence = PostgresKindPersistence()
                    MemoryKinds.seed(persistence)
                    MemoryKinds.attach(persistence)
                case 'mysql' =>
                    let persistence = MySqlKindPersistence()
                    MemoryKinds.seed(persistence)
                    MemoryKinds.attach(persistence)
                case _ => ()
            }
            kindsSeeded = true
        }catch(e: Exception){
            LoggerFactory.getLogger<StoreWiring>().warn('memory kind seed skipped: ${e.message}')
        }
    }

    private static func ensure(name: String, factory: () -> ContentStore): Unit {
        if(!Stores.containsContent(name)){
            Stores.registerContent(name, factory)
        }
    }

    private static func ensureMeta(name: String, factory: () -> MetaStore): Unit {
        if(!Stores.containsMeta(name)){
            Stores.registerMeta(name, factory)
        }
    }
}

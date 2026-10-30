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

import std.collection.*
import std.sync.Mutex

import fountain::f_bean.*

/**
 * `MemoryRepository` 适配器（0.1/0.2）：
 * 各实现包在加载时注册工厂，这里按 `llm_contentStore` 决定实例化哪个。
 *
 * 实现包（`f_llm.store.postgres` / `f_llm.store.mysql`）import 本包完成注册；
 * 本包**不 import 任何实现包**，避免循环依赖。
 */
public class MemoryRepositories {
    private static let mutex = Mutex()
    private static let factories = HashMap<String, () -> MemoryRepository>()

    public static func register(name: String, factory: () -> MemoryRepository): Bool {
        synchronized(mutex){
            if(factories.contains(name)){
                return false
            }
            factories[name] = factory
            true
        }
    }

    public static func names(): ArrayList<String> {
        synchronized(mutex){
            let result = ArrayList<String>()
            for((name, _) in factories){
                result.add(name)
            }
            result
        }
    }

    /**
     * 按配置 `llm_contentStore` 创建：由 `f_bean` 依据 `@BeanMeta[condition: ConfCond...]`
     * 选出匹配的实现；没有匹配时回退到 fhydra（尚未实现，直接抛错说明）。
     *
     * 该表达式只在首次调用时求值一次，之后由 bean 容器持有单例。
     */
    public static func create(): MemoryRepository {
        lookupOption<MemoryRepository>() ?? fallback()
    }

    private static func fallback(): MemoryRepository {
        throw IllegalStateException(
            'no MemoryRepository bean for llm_contentStore="${StoreSettings.load().contentStore}"; '
            + 'fhydra 内容族尚未实现，请配置 llm_contentStore=postgres|mysql')
    }

    public static func create(name: String): MemoryRepository {
        let factory = synchronized(mutex){
            factories.get(name)
        }
        match(factory){
            case Some(create) => create()
            case None => throw IllegalArgumentException('memory repository "${name}" is not registered, available: ${joined()}')
        }
    }

    /** 仅测试用 */
    public static func resetForTest(): Unit {
        synchronized(mutex){
            factories.clear()
        }
    }

    private static func joined(): String {
        var text = ''
        for(name in names()){
            if(!text.isEmpty()){
                text += ','
            }
            text += name
        }
        text
    }
}

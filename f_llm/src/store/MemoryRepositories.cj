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

    /** 按配置 `llm_contentStore` 创建；未注册时抛错并列出可选实现 */
    public static func create(): MemoryRepository {
        create(StoreSettings.load().contentStore)
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

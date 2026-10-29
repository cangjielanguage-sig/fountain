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

import fountain::f_config.*

/**
 * 存储工厂：按 `f_config` 的键选择内容族 / 元数据族实现。
 *
 * 注册只发生在启动期（`@Bean` 初始化或显式注册），因此不引入运行时锁；
 * 未知配置值一律抛错并列出可选列表，不做静默回退。
 */
public class Stores {
    public static const CONTENT_KEY = 'llm_contentStore'
    public static const META_KEY = 'llm_metaStore'
    public static const DEFAULT_CONTENT = 'postgres'
    public static const DEFAULT_META = 'postgres'

    private static let contentFactories = HashMap<String, () -> ContentStore>()
    private static let metaFactories = HashMap<String, () -> MetaStore>()

    public static func registerContent(name: String, factory: () -> ContentStore): Unit {
        if(contentFactories.contains(name)){
            throw IllegalArgumentException('content store already registered: ${name}')
        }
        contentFactories[name] = factory
    }

    public static func registerMeta(name: String, factory: () -> MetaStore): Unit {
        if(metaFactories.contains(name)){
            throw IllegalArgumentException('meta store already registered: ${name}')
        }
        metaFactories[name] = factory
    }

    /** 仅测试用：清空注册表，避免用例之间互相污染 */
    public static func resetForTest(): Unit {
        contentFactories.clear()
        metaFactories.clear()
    }

    /** 按配置选择内容族实现 */
    public static func content(): ContentStore {
        let name = StoreSettings.load().contentStore
        content(name)
    }

    /** 按名字选择内容族实现；未知名字给出可选列表 */
    public static func content(name: String): ContentStore {
        match(contentFactories.get(name)){
            case Some(factory) => factory()
            case None => throw IllegalArgumentException(
                'unknown llm_contentStore: ${name}, available: ${contentNames()}'
            )
        }
    }

    /** 按配置选择元数据族实现 */
    public static func meta(): MetaStore {
        let name = StoreSettings.load().metaStore
        meta(name)
    }

    /** 按名字选择元数据族实现；未知名字给出可选列表 */
    public static func meta(name: String): MetaStore {
        match(metaFactories.get(name)){
            case Some(factory) => factory()
            case None => throw IllegalArgumentException(
                'unknown llm_metaStore: ${name}, available: ${metaNames()}'
            )
        }
    }

    private static func contentNames(): String {
        let names = ArrayList<String>()
        for(key in contentFactories.keys()){
            names.add(key)
        }
        namesOf(names)
    }

    private static func metaNames(): String {
        let names = ArrayList<String>()
        for(key in metaFactories.keys()){
            names.add(key)
        }
        namesOf(names)
    }

    private static func namesOf(names: ArrayList<String>): String {
        var text = ''
        for(index in 0..names.size){
            if(index > 0){
                text += ', '
            }
            text += names[index]
        }
        text
    }
}

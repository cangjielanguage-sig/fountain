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

/**
 * `MemoryRepository` 适配器本体：对业务层只暴露接口，内部转发给
 * `f_bean` 依据 `llm_contentStore` 选出的实现（`MemoryRepositories.create()`）。
 *
 * 注意：本类**不加** `@Bean`，否则它会和 PG/MySQL 实现一起成为 `MemoryRepository` 的候选，
 * 造成 `lookupOption<MemoryRepository>()` 歧义或递归。
 */
public class MemoryRepositoryAdapter <: MemoryRepository {
    private let delegate: MemoryRepository

    public init() {
        this.delegate = MemoryRepositories.create()
    }

    public func upsert(write: MemoryWrite, titleVector: Array<Float64>,
                       contentVector: Array<Float64>): Int64 {
        delegate.upsert(write, titleVector, contentVector)
    }

    public func searchDense(query: MemoryQuery, vector: Array<Float64>, limit: Int64): ArrayList<MemoryHit> {
        delegate.searchDense(query, vector, limit)
    }

    public func searchSparse(query: MemoryQuery, tokens: HashMap<Int64, Float64>,
                             limit: Int64): ArrayList<MemoryHit> {
        delegate.searchSparse(query, tokens, limit)
    }

    public func upsertSparse(memoryId: Int64, userId: Int64, namespace: String,
                             tokens: HashMap<Int64, Float64>): Unit {
        delegate.upsertSparse(memoryId, userId, namespace, tokens)
    }

    public func upsertColbert(memoryId: Int64, titleVectors: Array<Array<Float64>>,
                              contentVectors: Array<Array<Float64>>): Unit {
        delegate.upsertColbert(memoryId, titleVectors, contentVectors)
    }

    public func colbert(recordId: Int64): ?ColbertVectors {
        delegate.colbert(recordId)
    }

    public func get(userId: Int64, id: Int64): ?MemoryRecord {
        delegate.get(userId, id)
    }

    public func list(userId: Int64, namespace: String, offset: Int64, limit: Int64): ArrayList<MemoryRecord> {
        delegate.list(userId, namespace, offset, limit)
    }

    public func remove(userId: Int64, id: Int64): Bool {
        delegate.remove(userId, id)
    }
}

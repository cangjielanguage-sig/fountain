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
package fdbm_custom_ext

import std.env.getVariable
import fountain::f_app.{Initializer, InitializerCollection}
import fountain::f_dbm.{IdGenerator, PartitionAlgorithm}

/** 扩展名可由环境变量覆盖：`hash` 用于验证"自定义不得覆盖内置"。 */
private func configuredName(key: String, fallback: String): String {
    match (getVariable(key)) {
        case Some(value) =>
            let name = value.trimAscii()
            if (name.isEmpty()) { fallback } else { name }
        case None => fallback
    }
}

/**
 * 自定义分区算法：按 key 的哈希稳定映射到 db0..db3。
 *
 * `static init` 把自己注册进 `InitializerCollection`，fdbm 的 `CustomLoader` 加载 `.so`
 * 后通过 `initialize()` 取到实例。
 */
public class MarkerPartition <: Initializer & PartitionAlgorithm {
    static init() {
        InitializerCollection.register(MarkerPartition())
    }

    public init() {}

    public prop name: String {
        get() {
            configuredName('CUSTOM_EXT_ALGORITHM', 'marker')
        }
    }

    public prop dependencies: Array<String> {
        get() {
            Array<String>()
        }
    }

    public func initialize(): Unit {}

    public func start(): Unit {}

    public func partition<K>(key: K): String {
        let any: Any = key
        let hash = match (any) {
            case value: Int64 => value
            case value: String => value.hashCode()
            case _ => 0
        }
        let bucket = ((hash % 4) + 4) % 4
        'db${bucket}'
    }
}

/** 自定义 ID 生成器：只实现整型 ID，字符串方法沿用接口默认实现（抛 `IdGeneratorException`）。 */
public class MarkerIdGenerator <: Initializer & IdGenerator {
    static init() {
        InitializerCollection.register(MarkerIdGenerator())
    }

    private var next: Int64 = 7000

    public init() {}

    public prop name: String {
        get() {
            configuredName('CUSTOM_EXT_IDGEN', 'markergen')
        }
    }

    public prop dependencies: Array<String> {
        get() {
            Array<String>()
        }
    }

    public func initialize(): Unit {}

    public func start(): Unit {}

    public func nextIntId(): Int64 {
        next += 1
        next
    }
}

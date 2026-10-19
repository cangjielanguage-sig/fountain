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
package fountain::fdbm.config

import std.collection.Map
import fountain::f_config.Config

/**
 * 配置读取的抽象：生产环境走 `f_config.Config`，用例注入内存表。
 *
 * 这样"非法配置"负例就不会把脏键写进全局 `Config`，污染同进程里的后续用例
 *（`Config` 没有删除接口，写进去就撤不回）。
 */
public interface ConfigSource {
    func get(key: String): ?String
    func all(): Map<String, String>
}

/** 生产实现：环境变量 / 命令行 / `Config.set`。 */
public class EnvConfigSource <: ConfigSource {
    public func get(key: String): ?String {
        Config.getString(key)
    }

    public func all(): Map<String, String> {
        Config.getAll()
    }
}

/** 用例实现：固定快照，不读写全局配置。 */
public class MapConfigSource <: ConfigSource {
    private let values: Map<String, String>

    public init(values: Map<String, String>) {
        this.values = values
    }

    public func get(key: String): ?String {
        values.get(key)
    }

    public func all(): Map<String, String> {
        values
    }
}

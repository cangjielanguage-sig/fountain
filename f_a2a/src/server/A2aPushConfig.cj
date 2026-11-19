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
package fountain::f_a2a.server

import std.collection.*
import std.sync.*

/** 一条推送配置：任务进入终态时往 url POST 一条通知，token 原样带回，便于客户端校验来源 */
public class A2aPushConfigEntry {
    public let taskId: String
    public let url: String
    public let token: String

    init(taskId: String, url: String, token: String) {
        this.taskId = taskId
        this.url = url
        this.token = token
    }
}

/** 任务 → 回调 URL 的注册表（内存实现，`Mutex` 保护） */
public class A2aPushConfigStore {
    private let mutex = Mutex()
    private let entries = HashMap<String, A2aPushConfigEntry>()

    public init() {
    }

    public func set(taskId: String, url: String, token: String): A2aPushConfigEntry {
        let entry = A2aPushConfigEntry(taskId, url, token)
        synchronized(mutex) {
            entries[taskId] = entry
        }
        entry
    }

    public func get(taskId: String): ?A2aPushConfigEntry {
        synchronized(mutex) {
            entries.get(taskId)
        }
    }

    public func remove(taskId: String): Bool {
        synchronized(mutex) {
            match (entries.remove(taskId)) {
                case Some(_) => true
                case None => false
            }
        }
    }
}

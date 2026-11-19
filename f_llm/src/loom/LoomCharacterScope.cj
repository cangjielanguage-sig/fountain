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

import std.sync.*

/**
 * 人格 / 提示词的归属用户。
 *
 * 与 `LoomMemoryPolicy` 分开：人格是提示词诉求，不该被「要不要提炼记忆」的开关与
 * 默认 `userId=0` 绑架。未安装时 `LoomRunner` 回落到记忆策略的 `userId`。
 *
 * 进程级单例，与 `LoomServices` / `LoomSchedules` 一致。
 */
public class LoomCharacterScope {
    private static let mutex: Mutex = Mutex()
    private static var installed: ?Int64 = None

    private init() {
    }

    /** 安装归属用户；`userId<=0` 视为未安装 */
    public static func install(userId: Int64): Unit {
        synchronized(mutex) {
            installed = if (userId > 0) {
                Some(userId)
            } else {
                None
            }
        }
    }

    public static func current(): ?Int64 {
        let box = ScopeBox()
        synchronized(mutex) {
            box.value = installed
        }
        box.value
    }

    public static func reset(): Unit {
        synchronized(mutex) {
            installed = None
        }
    }
}

/** `synchronized` 块是 Unit 语义，值用持有者带出 */
class ScopeBox {
    public var value: ?Int64 = None
}

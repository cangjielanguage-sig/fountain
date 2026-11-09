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
package fountain::f_probe

import std.collection.{ArrayList, HashMap}
import std.sync.Mutex

/**
 * 进程内线程安全的告警渠道注册表。
 *
 * 键为渠道名（例如 `email`），保存工厂。重名注册抛 [ProbeException]
 * （[ProbeErrorCode.DUPLICATE]），不覆盖已登记工厂。
 */
public class AlarmChannelRegistry {
    private static let lock = Mutex()
    private static let factories = HashMap<String, () -> AlarmMessageChannel>()

    /** 注册一个告警渠道工厂；渠道名必须唯一。 */
    public static func registerChannel(name: String, factory: () -> AlarmMessageChannel): Unit {
        synchronized(lock) {
            if (factories.contains(name)) {
                throw ProbeException(ProbeErrorCode.DUPLICATE, "duplicate alarm channel: ${name}")
            }
            factories.add(name, factory)
        }
    }

    /** 返回当前已注册的全部渠道名快照。 */
    public static func channels(): Array<String> {
        synchronized(lock) {
            let names = ArrayList<String>()
            for ((name, _) in factories) {
                names.add(name)
            }
            names.toArray()
        }
    }

    /** 按渠道名取工厂；不存在时返回 `None`。 */
    public static func channel(name: String): ?(() -> AlarmMessageChannel) {
        synchronized(lock) {
            factories.get(name)
        }
    }

    /** 清空注册表，仅供测试使用。 */
    public static func clear(): Unit {
        synchronized(lock) {
            factories.clear()
        }
    }
}

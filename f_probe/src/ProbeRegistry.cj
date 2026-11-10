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
 * 进程内线程安全的监控项注册表。
 *
 * 保存工厂而不是实例：注册通常发生在动态库加载期，此时运行期配置可能尚未校验。
 * 重名注册一律抛 [ProbeException]（[ProbeErrorCode.DUPLICATE]），内置探针先注册，
 * 扩展后加载，因此扩展不能覆盖内置 `kind`。
 */
public class ProbeRegistry {
    private static let lock = Mutex()
    private static let factories = HashMap<String, () -> ProbeAgent>()

    /** 注册一个监控项工厂；`kind` 必须全局唯一。 */
    public static func registerAgent(kind: String, factory: () -> ProbeAgent): Unit {
        synchronized(lock) {
            if (factories.contains(kind)) {
                throw ProbeException(ProbeErrorCode.DUPLICATE, "duplicate probe kind: ${kind}")
            }
            factories.add(kind, factory)
        }
    }

    /** 返回当前已注册的全部 `kind` 快照。 */
    public static func agents(): Array<String> {
        synchronized(lock) {
            let names = ArrayList<String>()
            for ((kind, _) in factories) {
                names.add(kind)
            }
            names.toArray()
        }
    }

    /** 按 `kind` 取工厂；不存在时返回 `None`。 */
    public static func agent(kind: String): ?(() -> ProbeAgent) {
        synchronized(lock) {
            factories.get(kind)
        }
    }

    /** 清空注册表，仅供测试使用。 */
    public static func clear(): Unit {
        synchronized(lock) {
            factories.clear()
        }
    }
}

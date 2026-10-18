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
package fountain::f_jit

import std.collection.HashMap
import std.collection.ArrayList
import std.sync.Mutex

/**
 * S6.6 适配器注册表（§8.2 第 5 步）：键 `(单元指纹, fnId, T 名)`。
 *
 * 宿主侧锁保护；`removeUnit` 按单元指纹整维移除（卸载路径，§8.7）。
 */
public class AdapterRegistry {
    private static let lock = Mutex()
    private static let adapters = HashMap<String, Int64>()
    private static let units = HashMap<String, ArrayList<String>>()

    /** 注册（同键覆盖；幂等）。 */
    public static func register(fingerprint: UInt64, fnId: UInt32, tName: String,
        adapter: Int64): Unit {
        let k = AdapterRegistry.key(fingerprint, fnId, tName)
        synchronized(lock) {
            adapters[k] = adapter
            let u = '${fingerprint}'
            match (units.get(u)) {
                case Some(list) => list.add(k)
                case None =>
                    let list = ArrayList<String>()
                    list.add(k)
                    units[u] = list
            }
        }
    }

    /** 查找；未注册 → None（调用方转 19）。 */
    public static func lookup(fingerprint: UInt64, fnId: UInt32, tName: String): ?Int64 {
        let k = AdapterRegistry.key(fingerprint, fnId, tName)
        synchronized(lock) {
            adapters.get(k)
        }
    }

    /** 按单元指纹移除全部适配器（卸载）；返回移除条数。 */
    public static func removeUnit(fingerprint: UInt64): Int64 {
        let u = '${fingerprint}'
        synchronized(lock) {
            match (units.get(u)) {
                case Some(list) =>
                    for (k in list) {
                        adapters.remove(k)
                    }
                    units.remove(u)
                    list.size
                case None => 0
            }
        }
    }

    /** 测试/诊断：当前注册总数。 */
    public static func size(): Int64 {
        synchronized(lock) {
            adapters.size
        }
    }

    private static func key(fingerprint: UInt64, fnId: UInt32, tName: String): String {
        '${fingerprint}/${fnId}/${tName}'
    }
}

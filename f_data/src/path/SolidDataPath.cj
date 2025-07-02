/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_data.path

import std.collection.concurrent.ConcurrentHashMap
import std.sync.Mutex

internal class SolidDataPath <: DataPath {
    private static let SOLID = ConcurrentHashMap<String, DataPath>()
    private static let lock = Mutex()
    private init() {}
    static func compile(path: String): DataPath {
        if (let Some(p) <- SOLID.get(path)) {
            p
        } else {
            synchronized(lock) {
                if (let Some(p) <- SOLID.get(path)) {
                    p
                } else {
                    let p = SolidDataPath().doCompile(path, true)
                    SOLID[path] = p
                    p
                }
            }
        }
    }
}

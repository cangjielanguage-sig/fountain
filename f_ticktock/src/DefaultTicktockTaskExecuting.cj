/*
    Copyright (c) 2022 WuJingrun（吴京润）
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_ticktock

import std.collection.concurrent.ConcurrentHashMap
import f_collection.*

class DefaultTicktockTaskExecuting {
    private static var executingMap = ConcurrentHashMap<String, Int64>()

    static func executing(name: String, stamp: Int64): Bool {
        executingMap.addIfAbsent(name, stamp).isSome()
    }

    static func reset(name: String, stamp: Int64): Unit {
        executingMap.removeIf(name) {v => v == stamp}
    }
}

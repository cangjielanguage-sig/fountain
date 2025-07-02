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

import f_cache.HeapCache

internal class CacheDataPath <: DataPath {
    private static let CACHE = HeapCache<DataPath>(maxLife: Duration.day, maxSize: 10000)
    private init() {}
    static func compile(path: String): DataPath {
        CACHE.getOrCompute(path) {CacheDataPath().doCompile(path, false)}
    }
}

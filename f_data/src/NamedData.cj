/*
    Copyright (c) 2022 WuJingrun（吴京润）
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_data

import std.collection.concurrent.ConcurrentMap

public interface NamedData {
    func get(name: String): ?Data
    operator func [](name: String): Data
}

extend<M, V> DataMap<M, String, V> <: NamedData where V <: DataFields<V>, M <: DataFields<M> & Map<String, V> {
    public func get(name: String): ?Data {
        this.data.get(name)?.toData()
    }
    public operator func [](name: String): Data {
        get(name).getOrThrow {DataException('key ${name} is not found in ${TypeInfos.get<M>()}')}
    }
}

extend<M, V> DataConcurrentMap<M, String, V> <: NamedData where V <: DataFields<V>,
    M <: DataFields<M> & ConcurrentMap<String, V> {
    public func get(name: String): ?Data {
        this.data.get(name)?.toData()
    }
    public operator func [](name: String): Data {
        get(name).getOrThrow {DataException('key ${name} is not found in ${TypeInfos.get<M>()}')}
    }
}

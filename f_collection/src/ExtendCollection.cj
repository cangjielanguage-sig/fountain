/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.  
*/
package f_collection

import std.collection.{Set, ArrayList}
import std.collection.concurrent.ConcurrentHashMap

public interface ExtendCollection<T, C> where T <: Equatable<T>, C <: Collection<T> {
    func retain(set: C): Unit
}
public interface ExtendList<T> <: ExtendCollection<T, Set<T>> where T <: Equatable<T> {
    func remove(set: Set<T>): Unit
}
extend<T> ArrayList<T> <: ExtendList<T> where T <: Equatable<T> {
    public func retain(set: Set<T>): Unit {
        batchRemove(set, true)
    }
    public func remove(set: Set<T>): Unit {
        batchRemove(set, false)
    }
    private func batchRemove(set: Set<T>, complement: Bool): Unit {
        let s = size
        var w = 0
        for(r in 0 .. s where set.contains(this[r]) == complement) {
            this[w] = this[r]
            w++
        }
        if(w == s) {
            return
        }
        for(i in s - 1 ..= w: -1){
            remove(at: i)
        }
    }
}
public interface ExtendMap<K, V> <: ExtendCollection<K, Collection<K>> where K <: Equatable<K> {
    func remove(k: K): ?V
    func contains(k: K): Bool
    func retain(c: Collection<K>): Unit {
        for(k in c where !contains(k)) {
            remove(k)
        }
    }
}
extend<K, V> HashMap<K, V> <: ExtendMap<K, V> where K <: Hashable & Equatable<K> {}
extend<K, V> TreeMap<K, V> <: ExtendMap<K, V> where K <: Comparable<K> {}
extend<K, V> LinkedHashMap<K, V> <: ExtendMap<K, V> where K <: Hashable & Equatable<K> {}
extend<K, V> ConcurrentHashMap<K, V> <: ExtendMap<K, V> where K <: Hashable & Equatable<K> {}
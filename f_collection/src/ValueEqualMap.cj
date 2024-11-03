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

public import std.collection.{HashMap, TreeMap}

public interface ValueEqualMap<K, V> <: ValueContainsMap<K, V> where K <: Equatable<K>, V <: Equal<V> {
    func values(): Collection<V>
    func containsValue(value: V): Bool {
        for(v in this.values() where v == value){
            return true
        }
        return false
    }
}
public interface ValueContainsMap<K, V> where K <: Equatable<K> {
    func values(): Collection<V>
    func containsValue(value: V, fn: (V, V) -> Bool): Bool {
        for(v in this.values() where fn(v, value)){
            return true
        }
        return false
    }
}

extend<K, V> HashMap<K, V> where K <: Hashable & Equatable<K>, V <: Equal<V> {
    
}
extend<K, V> HashMap<K, V> where K <: Hashable & Equatable<K> {
    
}
extend<K, V> TreeMap<K, V> where K <: Comparable<K>, V <: Equal<V> {

}
extend<K, V> TreeMap<K, V> where K <: Comparable<K>{

}
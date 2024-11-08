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
public import std.collection.concurrent.ConcurrentHashMap

public interface ValueContainsMap<K, V> where K <: Equatable<K> {
    func values(): Collection<V>
    func containsValue(predicate: (V) -> Bool): Bool {
        for(v in this.values() where predicate(v)){
            return true
        }
        return false
    }
}

public interface ValueEqualMap<K, V> where K <: Equatable<K>, V <: Equal<V> {
    func containsValue(predicate: (V) -> Bool): Bool
    func containsValue(value: V): Bool {
        containsValue{v => v == value}
    }
}
extend<K, V> HashMap<K, V> <: ValueEqualMap<K, V> where K <: Hashable & Equatable<K>, V <: Equal<V> {
    
}
extend<K, V> HashMap<K, V> <: ValueContainsMap<K, V> where K <: Hashable & Equatable<K> {
    
}
extend<K, V> TreeMap<K, V> <: ValueEqualMap<K, V> where K <: Comparable<K>, V <: Equal<V> {

}
extend<K, V> TreeMap<K, V> <: ValueContainsMap<K, V> where K <: Comparable<K>{

}
extend<K, V> LinkedHashMap<K, V> <: ValueEqualMap<K, V> where K <: Hashable & Equatable<K>, V <: Equal<V> {

}
extend<K, V> LinkedHashMap<K, V> <: ValueContainsMap<K, V> where K <: Hashable & Equatable<K> {

}
extend<K, V> ConcurrentHashMap<K, V> <: ValueEqualMap<K, V> where K <: Hashable & Equatable<K>, V <: Equal<V> {
    
}
extend<K, V> ConcurrentHashMap<K, V> <: ValueContainsMap<K, V> where K <: Hashable & Equatable<K> {
    public func values(): Collection<V>{
        ConcurrentHashMapValues<K, V>(this)
    }
}
public class ConcurrentHashMapValues<K, V> <: Collection<V> where K <: Hashable & Equatable<K> {
    public ConcurrentHashMapValues(private let map: ConcurrentHashMap<K, V>){}
    public func isEmpty(): Bool {
        map.isEmpty()
    }
    public prop size: Int64{
        get(){
            map.size
        }
    }
    public func iterator(): Iterator<V>{
        ConcurrentHashMapValueIterator<K, V>(map.iterator())
    }
}
public class ConcurrentHashMapValueIterator<K, V> <: Iterator<V> where K <: Hashable & Equatable<K> {
    public ConcurrentHashMapValueIterator(private let itr: Iterator<(K, V)>){}
    public func next(): ?V {
        itr.next()?[1]
    }
}
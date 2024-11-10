/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.  
*/
package f_cache

import std.collection.Map
import std.sync.ReentrantMutex
import f_collection.{LinkedHashMap, ValueEqualMap, ValueContainsMap}

class SyncLinkedHashMap<V> <: Collection<(String, V)>{
    private let mutex = ReentrantMutex()
    private let map = LinkedHashMap<String, V>()
    public func iterator(): Iterator<(String, V)>{
        SyncLinkedHashMapIterator<V>(map.iterator(), mutex)
    }
    public func get(key: String): ?V{
        synchronized(mutex){
            map.get(key)
        }
    }
    public func contains(key: String): Bool {
        synchronized(mutex){
            map.contains(key)
        }
    }
    public func put(key: String, value: V): ?V{
        synchronized(mutex){
            map.put(key, value)
        }
    }
    public func computeIfAbsent(key: String, callable: ()->V): V{
        synchronized(mutex){
            if(let Some(v) <- get(key)){
                v
            }else{
                let v = callable()
                put(key, v)
                v
            }
        }
    }
    public func remove(key: String): ?V{
        synchronized(mutex){
            map.remove(key)
        }
    }
    public prop size: Int64{
        get(){
            synchronized(mutex){
                map.size
            }
        }
    }
    public func isEmpty(): Bool {
        synchronized(mutex){
            map.isEmpty()
        }
    }
    public func clear(): Unit {
        synchronized(mutex){
            map.clear()
        }
    }
}
class SyncLinkedHashMapIterator<V> <: Iterator<(String, V)>{
    SyncLinkedHashMapIterator(private let itr: Iterator<(String, V)>,
                              private let mutex: ReentrantMutex){}
    public func next(): ?(String, V){
        synchronized(mutex){
            itr.next()
        }
    }
}
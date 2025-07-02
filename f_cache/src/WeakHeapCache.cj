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

import std.ref.*
import std.collection.concurrent.ConcurrentHashMap
import f_collection.*

public class WeakHeapCache<T> where T <: Object {
    private let cache = ConcurrentHashMap<String, WeakRef<T>>()
    
    public func set(key: String, value: T): ?T {
        if(let Some(r) <- cache.get(key)){
            if(let Some(v) <- r.value){
                return v
            }
            cache.remove(key)
        }
        None<T>
    }
    public func getOrCompute(key: String, fn: () -> ?T): ?T {
        cache.entryView(key){entry => 
            if(let Some(r) <- entry.value && let Some(v) <- r.value){
            }else {
                entry.value = if(let Some(v) <- fn()){
                    WeakRef<T>(v, DEFERRED)
                }else{
                    None
                }
            }
        }?.value ?? None<T>
    }
    public func get(key: String): ?T {
        if(let Some(r) <- cache.get(key)){
            if(let Some(v) <- r.value){
                return v
            }else{
                cache.remove(key)
            }
        }
        None<T>
    }
    public func getOrDefault(key: String, default: T): T {
        get(key) ?? default
    }
    public func getOrStore(key: String, value: T): T {
        getOrCompute(key){value} ?? value
    }
    public func remove(key: String): ?T {
        cache.remove(key)?.value ?? None<T>
    }
    public func removeIf(predicate: (String, T) -> Bool): Unit {
        cache.removeIf{k, r => 
            if(let Some(v) <- r.value) {
                predicate(k, v)
            }else{
                true
            }
        }
    }
    public prop size: Int64 {
        get(){
            cache.size
        }
    }
    public func clear(): Unit {
        removeIf{_, _ => true}
    }
}
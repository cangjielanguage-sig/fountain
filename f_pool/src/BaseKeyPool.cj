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
package fountain::f_pool

import std.collection.concurrent.ConcurrentHashMap
import std.sync.AtomicInt64


struct BaseKeyPool<K, V> <: IKeyPool<K, V> where K <: Hashable & Equatable<K> {
    private let map = ConcurrentHashMap<K, BasePool<V>>()
    private let poolCreator: (K) -> BasePool<V>
    private let s = AtomicInt64(0)
    BaseKeyPool(mode: Mode, private let max: Int64){
        poolCreator = mode.poolCreator()
    }
    public func add(key: K, value: V): Unit {
        keyedPool(key).add(value) 
        s.fetchAdd(1)
    }
    public func giveBack(key: K, value: V, checker: (K, V) -> Bool, destroier: (K, V) -> Unit): Unit {
        map.get(key)?.giveBack(value, keyedChecker(key, checker), keyedDestroier(key, destroier))
    }
    private func keyedChecker(key: K, checker: (K, V) -> Bool) {
        {v: V => 
            if(checker(key, v)){
                true
            }else{
                s.fetchSub(1)
                false
            }
        }
    }
    private func keyedDestroier(key: K, destroier: (K, V) -> Unit) {
        {v: V => 
            destroier(key, v)
        }
    }
    public func get(key: K, checker: (K, V) -> Bool, destroier: (K, V) -> Unit): ?V {
        keyedPool(key).get(keyedChecker(key, checker), keyedDestroier(key, destroier))
    }
    public func check(running: () -> Bool, checker: (K, V) -> Bool, taskPusher: (K) -> Unit): Unit {
        for ((k, p) in map){
            p.check(running, {v => p.size < max && checker(k, v)}){taskPusher(k)} |> 
            s.fetchSub
            if(!running()){
                return
            }
            sleep(Duration.Zero)
        }
    }
    public func destroy(fn: (K, V) -> Unit): Unit {
        for((k, p) in map){
            p.destroy{v => fn(k, v)}
        }
    }
    public prop size: Int64 {
        get(){
            return s.load()
        }
    }
    private func keyedPool(key: K): BasePool<V> {
        map.entryView(key){view => 
            if(let Some(p) <- view.value){
                p
            }else{
                let p = poolCreator(key)
                view.value = p
                p
            }
        }.getOrThrow()
    }
    public func keyedSize(key: K): Int64 {
        keyedPool(key).size
    }
    public func entries(): Iterator<(K, Int64)> {
        map.iterator().map{tpl => (tpl[0], tpl[1].size)}
    }
}

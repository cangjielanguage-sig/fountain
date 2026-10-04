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
import fountain::f_pool.diagnostics.PoolDiagnostics


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
    /**
     * 主动审计自愈：先让每个 key 的队列自愈，再把全局计数 `s` 与各队列之和校正一致。
     * `s` 里既有空闲项也有借出项（借出不会从队列计数里减掉），所以两者**任何时刻**都该相等，
     * 不等就是真脱钩 —— 校正它可以让 `get` 不再误以为"池已满"（见 bug.md 7.2 / 7.12）。
     */
    public func audit(): Int64 {
        var healed = 0
        var total = 0
        for((_, p) in map){
            sleep(Duration.Zero)
            healed += p.audit()
            total += p.size
        }
        let current = s.load()
        if (current != total) {
            s.store(total)
            PoolDiagnostics.onBookkeepingHealed()
            healed += 1
            // 不在这里打日志：`size a -> b` 由调用方（`KeyPool` 巡检）统一 WARN 出来，
            // 避免同一次校正既被底层打、又被上层打（见 bug.md 7.12）
        }
        healed
    }
    public func destroy(fn: (K, V) -> Unit): Unit {
        for((k, p) in map){
            // 队列自己的计数由 check/onRemoved 维护；这里的全局计数 s 也必须同步减掉，
            // 否则 destroy 之后 size 仍报旧值、后续 get 会以为池已满而不再新建池项（见 bug.md 7.2）
            s.fetchSub(p.destroy{v => fn(k, v)})
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

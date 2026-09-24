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

struct UnitKeyPool<K, V> <: IKeyPool<K, V> {
    private let eternity: K
    private let pool: BasePool<V>
    UnitKeyPool(mode: Mode, private let max: Int64){
        let eternity = (() as K).getOrThrow()
        this.eternity = eternity
        pool = mode.createPool()
    }
    public func add(_: K, value: V): Unit {
        pool.add(value)
    }
    public func giveBack(_: K, value: V, checker: (K, V) -> Bool, destroier: (K, V) -> Unit): Unit{
        pool.giveBack(value, keyedChecker(checker), keyedDestroier(destroier))
    }
    private func keyedChecker(checker: (K, V) -> Bool) {
        {v => checker(eternity, v)}
    }
    private func keyedDestroier(destroier: (K, V) -> Unit) {
        {v => destroier(eternity, v)}
    }
    public func get(_: K, checker: (K, V) -> Bool, destroier: (K, V) -> Unit): ?V {
        pool.get(keyedChecker(checker), keyedDestroier(destroier))
    }
    public func check(running: () -> Bool, checker: (K, V) -> Bool, taskPusher: (K) -> Unit): Unit{
        pool.check(running, {v => size < max && checker(eternity, v)}){taskPusher(eternity)}
    }
    public func destroy(fn: (K, V) -> Unit): Unit {
        pool.destroy{v => fn(eternity, v)}
    }
    public prop size: Int64{
        get(){
            pool.size
        }
    }
    public func keyedSize(_: K): Int64 {
        size
    }
    public func entries(): Iterator<(K, Int64)>{
        [(eternity, pool.size)].iterator()
    }
}
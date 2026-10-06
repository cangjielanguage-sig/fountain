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
        // 单键池：入池失败（池已关闭）时这个值由调用方的 `Ref` 终结器兜底销毁
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
        // 同 `BaseKeyPool.check`：`size < max` 只约束「补建」，不能当 checker 的与条件
        // （见 .autocode/bugs/bug-pool.md §1.3 POOL-3）
        pool.check(running, {v => checker(eternity, v)}){if (size < max) { taskPusher(eternity) }}
    }
    /**
     * 单键池的 `remove` 等价于「关掉这唯一的池」：关闭 + 销毁池项之后，`get` 一直返回 `None`
     * （这个接口只为 `IKeyPool` 完整性存在 —— `Pool<V>` 不暴露 `remove`）。
     */
    public func remove(_: K, fn: (K, V) -> Unit): Unit {
        pool.close{v => fn(eternity, v)}
    }
    /** 关闭并销毁这唯一的池（`IKeyPool.close`）。 */
    public func close(fn: (K, V) -> Unit): Unit {
        pool.close{v => fn(eternity, v)}
    }
    public func audit(): Int64 {
        pool.audit()
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
    /** 单键池：键数恒为 1（哪怕是已关闭的池）。 */
    public func keyCount(): Int64 {
        1
    }
}
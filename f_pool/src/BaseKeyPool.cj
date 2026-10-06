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

import std.collection.ArrayList
import std.collection.concurrent.ConcurrentHashMap
import std.sync.{AtomicBool, AtomicInt64}
import fountain::f_pool.diagnostics.PoolDiagnostics
import fountain::f_pool.exception.UnknownKeyException


struct BaseKeyPool<K, V> <: IKeyPool<K, V> where K <: Hashable & Equatable<K> {
    private let map = ConcurrentHashMap<K, BasePool<V>>()
    private let poolCreator: (K) -> BasePool<V>
    private let s = AtomicInt64(0)
    /**
     * `running` 是所属 `KeyPool` 的运行标志（同一个 `AtomicBool`，**成员参数**）：
     * 关停之后不再按需建池 —— 否则 `close()` 清空键表之后，一个交错的 `get` / `keyedSize`
     * 又会把键表长回来（见 `POOL-11`）。
     */
    BaseKeyPool(mode: Mode, private let max: Int64, private let running: AtomicBool){
        poolCreator = mode.poolCreator()
    }
    public func add(key: K, value: V): Unit {
        if (!running.load()) {
            // 关停窗口：不再建池、不再入池（这个值由调用方的 `Ref` 终结器兜底销毁）
            return
        }
        if (keyedPool(key).add(value)) {
            s.fetchAdd(1)
        }
    }
    public func giveBack(key: K, value: V, checker: (K, V) -> Bool, destroier: (K, V) -> Unit): Unit {
        if (let Some(p) <- map.get(key)) {
            p.giveBack(value, keyedChecker(key, checker), keyedDestroier(key, destroier))
            return
        }
        if (!running.load()) {
            // 关停与归还交错（`close()` 已经清空了键表）：归还无门 ⇒ 直接销毁，不抛
            // （口径同 `KeyPool.giveBack` 的 `!running` 分支）。
            unreturnable(key, value, destroier)
            return
        }
        // 这个键从来没有过池 ⇒ 调用方**还错了键**（键一旦被 get/add 用过就一定有池）。
        // 这是应用层的错，池不替它决定：不归还、不销毁、也不替它建一个池 —— 池项所有权仍归调用方，
        // 抛出来让它自己处置；被顶掉的异常可用 `addSuppressed` 挂上（见 .autocode/bugs/bug-pool.md §2.5 POOL-10）。
        throw UnknownKeyException(key)
    }
    /** 归还无门时的销毁（关停窗口）：回调异常只记数，销毁计数照记。 */
    private func unreturnable(key: K, value: V, destroier: (K, V) -> Unit): Unit {
        try {
            destroier(key, value)
        } catch (e: Exception) {
            PoolDiagnostics.onCallbackError()
        }
        PoolDiagnostics.onItemDestroyed()
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
        if (!running.load()) {
            return None<V>    // 关停之后不再按需建池（否则键表会从 close() 之后长回来，见 POOL-11）
        }
        keyedPool(key).get(keyedChecker(key, checker), keyedDestroier(key, destroier))
    }
    public func check(running: () -> Bool, checker: (K, V) -> Bool, taskPusher: (K) -> Unit): Unit {
        for ((k, p) in map){
            // checker **必须照常执行**：`p.size < max` 不能写成它的与条件 —— checker 返回 false 在
            // `SyncDeque.check` 里的语义是「这一项失效 ⇒ 摘节点」，满载（= 稳态）时那样写会
            // 每轮巡检丢一个空闲项、而且整轮**跳过用户 checker**（idleTimeout/connectionLife 判定被绕过）。
            // 它本来要约束的是「补建」，所以挪到 taskPusher 上（见 .autocode/bugs/bug-pool.md §1.3 POOL-3）。
            p.check(running, {v => checker(k, v)}){if (p.size < max) { taskPusher(k) }} |> 
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
     * 不等就是真脱钩 —— 校正它可以让 `get` 不再误以为"池已满"（见 .autocode/bugs/bug-archived-on-20261004.md 7.2 / 7.12）。
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
            // 避免同一次校正既被底层打、又被上层打（见 .autocode/bugs/bug-archived-on-20261004.md 7.12）
        }
        healed
    }
    /**
     * 摘掉 `key` 的池：**先关闭并销毁**它的池项（逐个交给 `fn`），再从键表里删掉它。
     *
     * 先 `map.remove(key)` 再关闭：这样并发的 `giveBack` 要么在删之前拿到池（由池的关闭标志拦住，
     * 见 `BasePool.close`），要么在删之后拿到 `None`（走关停/还错键的处理），不会把项塞进死池。
     * 键不存在时是空操作（`close()` 清空键表之后再调用也安全）。
     *
     * `s` 扣掉的是这个池**名下全部**（空闲 + 借出）：池一旦出表，它名下的东西就不再进账本了
     * （还在借用方手里的项，其账目由借用方自己负责 —— `giveBack` 会抛 `UnknownKeyException`）。
     */
    public func remove(key: K, fn: (K, V) -> Unit): Unit {
        if (let Some(p) <- map.remove(key)) {
            // 队列自己的计数由池的 close 维护；这里的全局计数 s 也要同步减掉，
            // 否则摘掉键之后 size 仍报旧值、后续 get 会以为池已满而不再新建池项（见 .autocode/bugs/bug-archived-on-20261004.md 7.2）
            s.fetchSub(p.size)
            p.close{v => fn(key, v)}
        }
    }
    /**
     * 关闭并销毁**全部**键的池，然后清空键表（`ConcurrentHashMap` 没有 `clear` ⇒ 先快照键再逐个摘）。
     * 关停之后不会再有键被建出来（`add` / `get` / `keyedSize` 都判 `running`），所以快照就是全集。
     * 最后一件事是把 `s` 清零：借出中的项随池一起出账（它们在借用方手里，由借用方自己处置）。
     */
    public func close(fn: (K, V) -> Unit): Unit {
        let keys = ArrayList<K>()
        for ((k, _) in map) {
            keys.add(k)
        }
        for (k in keys) {
            remove(k, fn)
        }
        s.store(0)
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
        if (!running.load()) {
            return 0        // 关停后不再按需建池（否则键表会从 close 之后长回来）
        }
        keyedPool(key).size
    }
    public func entries(): Iterator<(K, Int64)> {
        map.iterator().map{tpl => (tpl[0], tpl[1].size)}
    }
    public func keyCount(): Int64 {
        map.size
    }
}

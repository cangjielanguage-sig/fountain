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
protected package fountain::f_pool.base

import std.sync.AtomicBool
import fountain::f_pool.base.collection.{SyncDeque, WeakSyncDeque}
import fountain::f_pool.diagnostics.PoolDiagnostics

protected interface BasePool<T> {
    /**
     * 入池。**池已关闭**（`close` 之后）时不再入池 —— 调用方的 `Ref` 终结器会兜底销毁这个值。
     * 返回是否入池成功（`false` = 池已关闭，值没进去）。
     */
    func add(value: T): Bool
    func giveBack(value: T, checker: (T) -> Bool, destroier: (T) -> Unit): Unit
    func get(checker: (T) -> Bool, destroier: (T) -> Unit): ?T
    func check(running: () -> Bool, checker: (T) -> Bool, taskPusher: () -> Unit): Int64 
    /** 主动审计自愈（巡检线程每轮调用，见 .autocode/bugs/bug-archived-on-20261004.md 7.12）：返回校正的动作数。 */
    func audit(): Int64
    /**
     * **关闭并清空**这个池：先置关闭标志（此后 `add` / `get` / `giveBack` 都不再碰队列），
     * 再把池项逐个交给 `destroier` 销毁，返回销毁掉的数量 —— 调用方（`BaseKeyPool`）据此同步全局计数
     * （见 .autocode/bugs/bug-archived-on-20261004.md 7.2）。
     *
     * 这是本层唯一的「销毁」入口：不再有 `destroy`（`POOL-11`）——
     * 池被摘掉（`KeyPool.remove(key)` / `KeyPool.close()`）时都必须先关闭、再销毁。
     */
    func close(destroier: (T) -> Unit): Int64
    prop size: Int64
}

/**
 * 关闭时销毁一项的统一记账：与 `SyncDeque.discardItem` 同口径 ——
 * `destroier` 抛异常只记 `callbackError` 不外抛（销毁一项不能因为回调出错而中断整轮清空），
 * 销毁计数照记。
 */
private func closeDestroyed<T>(destroier: (T) -> Unit, value: T): Unit {
    try {
        destroier(value)
    } catch (e: Exception) {
        PoolDiagnostics.onCallbackError()
    }
    PoolDiagnostics.onItemDestroyed()
}


protected struct FifoPool<T> <: BasePool<T> {
    private let q = SyncDeque<T>()
    /** 已关闭（`close` 之后）：`add` / `get` / `giveBack` 都不再碰队列（`POOL-11`）。 */
    private let closed = AtomicBool(false)
    public func add(value: T): Bool {
        if (closed.load()) {
            return false
        }
        q.insertTail(value)
        true
    }
    public func giveBack(value: T, checker: (T) -> Bool, destroier: (T) -> Unit): Unit {
        if (closed.load()) {
            closeDestroyed(destroier, value)         // 关闭后归还：直接销毁，不让它在死池里滞留
            return
        }
        q.append(value, checker, destroier)
        if (closed.load()) {
            // 关闭与归还交错：这一项可能是在「清空」之后才入队的 ⇒ 队列里剩下的都已是死项，全部销毁
            // （关闭后 `add` / `giveBack` 都被挡住 ⇒ 队列只减不增）。
            // `remove` 的 checker 恒 false ⇒ 走 `discardItem`：销毁 + 结清借出/节点计数。
            while (let Some(_) <- q.remove({_ => false}, destroier)) {}
        }
    }
    public func get(checker: (T) -> Bool, destroier: (T) -> Unit): ?T {
        if (closed.load()) {
            return None<T>
        }
        return q.remove(checker, destroier)
    }
    public func check(running: () -> Bool, checker: (T) -> Bool, taskPusher: () -> Unit): Int64 {
        q.check(running, checker, taskPusher)
    }
    public func audit(): Int64 {
        q.audit()
    }
    public func close(destroier: (T) -> Unit): Int64 {
        closed.store(true)                           // 必须先置标志再清空：晚到的 add / giveBack 会被挡住
        q.check({=> true}, {v =>
            closeDestroyed(destroier, v)
            false
        }){}
    }
    public prop size: Int64 {
        get(){
            return q.size
        }
    }
}
protected struct LifoPool<T> <: BasePool<T> {
    private let q = SyncDeque<T>()
    /** 已关闭（`close` 之后）：`add` / `get` / `giveBack` 都不再碰队列（`POOL-11`）。 */
    private let closed = AtomicBool(false)
    public func add(value: T): Bool {
        if (closed.load()) {
            return false
        }
        q.insertHead(value)
        true
    }
    public func giveBack(value: T, checker: (T) -> Bool, destroier: (T) -> Unit): Unit {
        if (closed.load()) {
            closeDestroyed(destroier, value)         // 关闭后归还：直接销毁，不让它在死池里滞留
            return
        }
        q.prepend(value, checker, destroier)
        if (closed.load()) {
            // 关闭与归还交错：这一项可能是在「清空」之后才入队的 ⇒ 队列里剩下的都已是死项，全部销毁
            // （关闭后 `add` / `giveBack` 都被挡住 ⇒ 队列只减不增）。
            while (let Some(_) <- q.remove({_ => false}, destroier)) {}
        }
    }
    public func get(checker: (T) -> Bool, destroier: (T) -> Unit): ?T {
        if (closed.load()) {
            return None<T>
        }
        return q.remove(checker, destroier)
    }
    public func check(running: () -> Bool, checker: (T) -> Bool, taskPusher: () -> Unit): Int64 {
        q.check(running, checker, taskPusher)
    }
    public func audit(): Int64 {
        q.audit()
    }
    public func close(destroier: (T) -> Unit): Int64 {
        closed.store(true)                           // 必须先置标志再清空：晚到的 add / giveBack 会被挡住
        q.check({=> true}, {v =>
            closeDestroyed(destroier, v)
            false
        }){}
    }
    public prop size: Int64 {
        get(){
            return q.size
        }
    }
}

protected struct WeakFifoPool<T> <: BasePool<T> {
    private let q = WeakSyncDeque<T>()
    /** 已关闭（`close` 之后）：`add` / `get` / `giveBack` 都不再碰队列（`POOL-11`）。 */
    private let closed = AtomicBool(false)
    public func add(value: T): Bool {
        if (closed.load()) {
            return false
        }
        q.insertTail(value)
        true
    }
    public func giveBack(value: T, checker: (T) -> Bool, destroier: (T) -> Unit): Unit {
        if (closed.load()) {
            closeDestroyed(destroier, value)         // 关闭后归还：直接销毁，不让它在死池里滞留
            return
        }
        q.append(value, checker, destroier)
        if (closed.load()) {
            // 关闭与归还交错：队列里剩下的都已是死项，全部销毁（关闭后 add/giveBack 被挡住 ⇒ 只减不增）。
            while (let Some(_) <- q.remove({_ => false}, destroier)) {}
        }
    }
    public func get(checker: (T) -> Bool, destroier: (T) -> Unit): ?T {
        if (closed.load()) {
            return None<T>
        }
        q.remove(checker, destroier)
    }
    public func check(running: () -> Bool, checker: (T) -> Bool, taskPusher: () -> Unit): Int64 {
        q.check(running, checker, taskPusher)
    }
    public func audit(): Int64 {
        q.audit()
    }
    public func close(destroier: (T) -> Unit): Int64 {
        closed.store(true)                           // 必须先置标志再清空：晚到的 add / giveBack 会被挡住
        q.check({=> true}, {v =>
            closeDestroyed(destroier, v)
            false
        }){}
    }
    public prop size: Int64 {
        get(){
            return q.size
        }
    }
}
protected struct WeakLifoPool<T> <: BasePool<T> {
    private let q = WeakSyncDeque<T>()
    /** 已关闭（`close` 之后）：`add` / `get` / `giveBack` 都不再碰队列（`POOL-11`）。 */
    private let closed = AtomicBool(false)
    public func add(value: T): Bool {
        if (closed.load()) {
            return false
        }
        q.insertHead(value)
        true
    }
    public func giveBack(value: T, checker: (T) -> Bool, destroier: (T) -> Unit): Unit {
        if (closed.load()) {
            closeDestroyed(destroier, value)         // 关闭后归还：直接销毁，不让它在死池里滞留
            return
        }
        q.prepend(value, checker, destroier)
        if (closed.load()) {
            // 关闭与归还交错：队列里剩下的都已是死项，全部销毁（关闭后 add/giveBack 被挡住 ⇒ 只减不增）。
            while (let Some(_) <- q.remove({_ => false}, destroier)) {}
        }
    }
    public func get(checker: (T) -> Bool, destroier: (T) -> Unit): ?T {
        if (closed.load()) {
            return None<T>
        }
        q.remove(checker, destroier)
    }
    public func check(running: () -> Bool, checker: (T) -> Bool, taskPusher: () -> Unit): Int64 {
        q.check(running, checker, taskPusher)
    }
    public func audit(): Int64 {
        q.audit()
    }
    public func close(destroier: (T) -> Unit): Int64 {
        closed.store(true)                           // 必须先置标志再清空：晚到的 add / giveBack 会被挡住
        q.check({=> true}, {v =>
            closeDestroyed(destroier, v)
            false
        }){}
    }
    public prop size: Int64 {
        get(){
            return q.size
        }
    }
}
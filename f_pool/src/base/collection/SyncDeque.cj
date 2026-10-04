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
protected package fountain::f_pool.base.collection

import std.sync.{Mutex, AtomicInt64}
import std.ref.*

/** 操作代号 → 名字：不变量告警里带上"当时在跑哪类操作"，便于再现时定位触发源（见 bug.md 7.2）。 */
private let DEQUE_OP_NAMES = ['insertHead', 'insertTail', 'prepend', 'append', 'remove', 'check', 'reconcile']

protected interface Deque<T> {
    func insertHead(value: T): Unit
    func insertTail(value: T): Unit
    func prepend(value: T, checker: (T) -> Bool, destroier: (T) -> Unit): Unit
    func append(value: T, checker: (T) -> Bool, destroier: (T) -> Unit): Unit
    func remove(checker: (T) -> Bool, destroier: (T) -> Unit): ?T
    func check(running: () -> Bool, checker: (T) -> Bool, taskPusher: () -> Unit): Int64
    prop size: Int64
}
public class SyncDeque<T> <: Deque<T> {
    private let head = HeadNode<T>(Mutex())
    private var s = AtomicInt64(0)
    /** 已借出（不在队列里）的数量。不变量：s ≡ 队列节点数 + out。 */
    private let out = AtomicInt64(0)

    private let opCount = AtomicInt64(0)
    /** 最近一次进入的操作代号（诊断用，见 bug.md 7.2）。 */
    private let lastOp = AtomicInt64(0)

    /**
     * 低频自检：不变量 s ≡ 队列节点数 + out，**在 head.globalLock 临界区内**核对
     * （临界区外采集分不清「真丢项」与「并发中间态」，见 bug.md 7.2）。
     * 重复归还（同一对象两次）会让队列里出现重复节点，从而在此暴露；
     * 告警带「最近一次操作」以便再现时定位触发源；这里只告警（不改变行为），
     * 取不到项时的自愈在 reconcileIfWedge() 里做。
     */
    private func selfCheck(): Unit {
        if (opCount.fetchAdd(1) % 10000 != 0) {
            return
        }
        synchronized(head.globalLock){
            let (total, _) = countNodes()
            let o = out.load()
            let sa = s.load()
            if (sa != total + o) {
                println("DEQUE-SELFCHECK] invariant broken: size=${sa} nodes=${total} out=${o}, lastOp=${DEQUE_OP_NAMES[lastOp.load()]}")
            }
        }
    }

    private func markBorrowed(): Unit {
        out.fetchAdd(1)
    }

    private func markReturned(): Unit {
        if (out.load() > 0) {
            out.fetchSub(1)
        }
    }

    /** 只读遍历队列，返回 (节点总数, idle 数)。用于自愈前的现场核对。 */
    private func countNodes(): (Int64, Int64) {
        var total = 0
        var idles = 0
        var node: ?Node<T> = head.nextForCount()
        while(let Some(n: ValueNode<T>) <- node){
            total += 1
            if(n.idle){ idles += 1 }
            node = n.nextForCount()
        }
        (total, idles)
    }
    public func insertHead(value: T): Unit {
        lastOp.store(0)
        synchronized(head.globalLock){
            head.insertNext(value)
            s.fetchAdd(1)
        }
        selfCheck()
    }
    public func insertTail(value: T): Unit {
        lastOp.store(1)
        synchronized(head.globalLock){
            head.tail.insertPrev(value)
            s.fetchAdd(1)
        }
        selfCheck()
    }
    public func prepend(value: T, checker: (T) -> Bool, destroier: (T) -> Unit): Unit {
        lastOp.store(2)
        if(checker(value)){
            synchronized(head.globalLock){
                head.insertNext(value)
                markReturned()
            }
        }else{
            destroier(value)
            synchronized(head.globalLock){
                markReturned()
                s.fetchSub(1)
            }
        }
        selfCheck()
    }
    public func append(value: T, checker: (T) -> Bool, destroier: (T) -> Unit): Unit {
        lastOp.store(3)
        if(checker(value)){
            synchronized(head.globalLock){
                head.tail.insertPrev(value)
                markReturned()
            }
        }else{
            destroier(value)
            synchronized(head.globalLock){
                markReturned()
                s.fetchSub(1)
            }
        }
        selfCheck()
    }
    public func remove(checker: (T) -> Bool, destroier: (T) -> Unit): ?T {
        lastOp.store(4)
        while(true){
            // 取节点与借出计数必须在同一临界区：否则并发下会出现「节点已摘掉、计数未加」
            // 的中间态，把合法并发误判成记账脱钩（自愈就会误伤）。
            var taken = None<T>
            synchronized(head.globalLock){
                if(let Some(x) <- head.nextForGet()){
                    markBorrowed()
                    taken = Some(x)
                }
            }
            if(let Some(x) <- taken){
                if(checker(x)){
                    selfCheck()
                    return x
                }else{
                    destroier(x)
                    synchronized(head.globalLock){
                        markReturned()
                        s.fetchSub(1)
                    }
                    selfCheck()
                }
            }else{
                break
            }
        }
        reconcileIfWedge()
        None
    }

    /**
     * 自愈：s 记着有池项，但队列为空、且没有任何借出项 —— 说明记账已脱钩
     * （节点被并发摘掉/漏减，见 .autocode/bug.md 六）。此时调用者会永久取不到项，
     * 把 s 拉回真实值即可让池重新创建池项。
     */
    private func reconcileIfWedge(): Unit {
        lastOp.store(6)
        synchronized(head.globalLock){
            if (s.load() - out.load() <= 0) {
                return                  // 正常：队列里有项，或池项都在借出中
            }
            let (total, _) = countNodes()
            if (total == 0 && out.load() == 0 && s.load() > 0) {
                let lost = s.load()
                s.store(0)
                println("WEDGE-HEAL] deque lost ${lost} element(s) with no borrower (bookkeeping broken), size reset to 0, lastOp=${DEQUE_OP_NAMES[lastOp.load()]}")
            }
        }
    }
    public func check(running: () -> Bool, checker: (T) -> Bool, taskPusher: () -> Unit): Int64 {
        lastOp.store(5)
        var rm = 0
        var node: ?Node<T> = head.tail.prevForChecking()
        while(let Some(n: ValueNode<T>) <- node){
            if(!running()){
                // 退出前必须把刚被标记 checking 的节点还原：否则它永远不会再 idle，
                // 既取不到也不会被清理，等于永久丢一个池项（size 与实际可借数脱钩）。
                n.setIdle()
                break
            }
            node = n.prevForChecking()
            // 摘节点与 s 递减必须在同一临界区（见 bug.md 7.4）：分属两处时会留下
            // 「节点已摘、s 未减」的中间态，被并发的不变量校验误判成记账脱钩。
            if(!n.check(checker, onRemoved: {=> s.fetchSub(1)})){
                taskPusher()
                rm++
            }
            sleep(Duration.Zero)
        }
        rm
    }
    public prop size: Int64 {
        get(){
            s.load()
        }
    }
}
protected struct WeakSyncDeque<T> <: Deque<T> {
    private let q = SyncDeque<WeakRef<Object>>()
    private func ref(value: T): WeakRef<Object>{
        match(value){
            case x: Object => WeakRef<Object>(x, DEFERRED)
            case x => WeakRef<Object>(Box<T>(x), DEFERRED)
        }
    }
    public func insertHead(value: T): Unit {
        q.insertHead(ref(value))
    }
    public func insertTail(value: T): Unit {
        q.insertTail(ref(value))
    }
    private func refChecker(checker: (T) -> Bool){
        {ref: WeakRef<Object> => 
            match(ref.value){
                case Some(x: T) => x
                case Some(x: Box<T>) => x.value
                case _ => return false
            } |> checker
        }
    }
    private func refDestroier(destroier: (T) -> Unit){
        {ref: WeakRef<Object> => 
            match(ref.value){
                case Some(x: T) => x
                case Some(x: Box<T>) => x.value
                case _ => return 
            } |> destroier
        }
    }
    public func prepend(value: T, checker: (T) -> Bool, destroier: (T) -> Unit): Unit {
        q.prepend(ref(value), refChecker(checker), refDestroier(destroier))
    }
    public func append(value: T, checker: (T) -> Bool, destroier: (T) -> Unit): Unit {
        q.append(ref(value), refChecker(checker), refDestroier(destroier))
    }
    public func remove(checker: (T) -> Bool, destroier: (T) -> Unit): ?T {
        if (let Some(ref: WeakRef<Box<T>>) <- q.remove(refChecker(checker), refDestroier(destroier))) {
            return ref.value?.value
        }
        return None
    }
    public func check(running: () -> Bool, checker: (T) -> Bool, taskPusher: () -> Unit): Int64 {
        q.check(running, refChecker(checker), taskPusher)
    }
    public prop size: Int64 {
        get(){
            q.size
        }
    }
}
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
        head.insertNext(value)
        s.fetchAdd(1)
    }
    public func insertTail(value: T): Unit {
        head.tail.insertPrev(value)
        s.fetchAdd(1)
    }
    public func prepend(value: T, checker: (T) -> Bool, destroier: (T) -> Unit): Unit {
        if(checker(value)){
            head.insertNext(value)
        }else{
            destroier(value)
            s.fetchSub(1)
        }
        markReturned()
    }
    public func append(value: T, checker: (T) -> Bool, destroier: (T) -> Unit): Unit {
        if(checker(value)){
            head.tail.insertPrev(value)
        }else{
            destroier(value)
            s.fetchSub(1)
        }
        markReturned()
    }
    public func remove(checker: (T) -> Bool, destroier: (T) -> Unit): ?T {
        while(let Some(x) <- head.nextForGet()){
            markBorrowed()
            if(checker(x)){
                return x
            }else{
                destroier(x)
                markReturned()
                s.fetchSub(1)
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
        if (s.load() - out.load() <= 0) {
            return                      // 正常：队列里有项，或池项都在借出中
        }
        let (total, _) = countNodes()
        if (total == 0 && out.load() == 0 && s.load() > 0) {
            let lost = s.load()
            s.store(0)
            println("WEDGE-HEAL] deque lost ${lost} element(s) with no borrower (bookkeeping broken), size reset to 0")
        }
    }
    public func check(running: () -> Bool, checker: (T) -> Bool, taskPusher: () -> Unit): Int64 {
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
            if(!n.check(checker)){
                s.fetchSub(1)
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
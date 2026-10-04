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
import fountain::f_pool.diagnostics.PoolDiagnostics

/** 操作代号 → 名字：不变量告警里带上"当时在跑哪类操作"，便于再现时定位触发源（见 bug.md 7.2）。 */
private let DEQUE_OP_NAMES = ['insertHead', 'insertTail', 'prepend', 'append', 'remove', 'check', 'reconcile']

protected interface Deque<T> {
    func insertHead(value: T): Unit
    func insertTail(value: T): Unit
    func prepend(value: T, checker: (T) -> Bool, destroier: (T) -> Unit): Unit
    func append(value: T, checker: (T) -> Bool, destroier: (T) -> Unit): Unit
    func remove(checker: (T) -> Bool, destroier: (T) -> Unit): ?T
    func check(running: () -> Bool, checker: (T) -> Bool, taskPusher: () -> Unit): Int64
    /** 主动审计自愈（巡检线程每轮调用）：返回校正的动作数，见 bug.md 7.12。 */
    func audit(): Int64
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
     * 正在执行的 `check()` 调用数（含「已标记 CHECKING、尚未处理/还原」的节点）。
     * 自愈只在它为 0 时动手：有 check 在飞时，非 idle 节点是合法的中间态（见 bug.md 7.2）。
     */
    private let checkers = AtomicInt64(0)

    /**
     * 低频自检：不变量 s ≡ 队列节点数 + out，**在 head.globalLock 临界区内**核对
     * （临界区外采集分不清「真丢项」与「并发中间态」，见 bug.md 7.2）。
     * 额外报「记着有项却一个也取不出来」的形态（滞留 CHECKING / check 卡在 checker 里），
     * 两种告警都带上现场：idle / checking / 在飞 check 数 / 最近一次操作。
     * 重复归还（同一对象两次）会让队列里出现重复节点，从而在此暴露；
     * 这里只告警（不改变行为），取不到项时的自愈在 reconcileIfWedge() 里做。
     */
    private func selfCheck(): Unit {
        if (opCount.fetchAdd(1) % 10000 != 0) {
            return
        }
        synchronized(head.globalLock){
            let (total, idles, checkings) = countNodes()
            let o = out.load()
            let sa = s.load()
            if (sa != total + o) {
                println("DEQUE-SELFCHECK] invariant broken: size=${sa} nodes=${total} out=${o}, lastOp=${DEQUE_OP_NAMES[lastOp.load()]}")
            }
            if (o == 0 && sa > 0 && idles == 0) {
                println("DEQUE-SELFCHECK] no takeable element: size=${sa} nodes=${total} idle=${idles} checking=${checkings} inFlightChecks=${checkers.load()}, lastOp=${DEQUE_OP_NAMES[lastOp.load()]}")
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

    /**
     * 只读遍历队列，返回 (节点总数, idle 数, checking 数)。用于自检与自愈前的现场核对。
     * 挂在队列上的节点只有 idle（可取）与非 idle（滞留在校验中，取不到）两种。
     */
    private func countNodes(): (Int64, Int64, Int64) {
        var total = 0
        var idles = 0
        var checkings = 0
        var node: ?Node<T> = head.nextForCount()
        while(let Some(n: ValueNode<T>) <- node){
            total += 1
            if(n.idle){
                idles += 1
            }else if(n.checking){
                checkings += 1
            }
            node = n.nextForCount()
        }
        (total, idles, checkings)
    }
    public func insertHead(value: T): Unit {
        lastOp.store(0)
        synchronized(head.globalLock){
            head.insertNext(value)
            s.fetchAdd(1)
        }
        PoolDiagnostics.onItemAdded()
        selfCheck()
    }
    public func insertTail(value: T): Unit {
        lastOp.store(1)
        synchronized(head.globalLock){
            head.tail.insertPrev(value)
            s.fetchAdd(1)
        }
        PoolDiagnostics.onItemAdded()
        selfCheck()
    }
    public func prepend(value: T, checker: (T) -> Bool, destroier: (T) -> Unit): Unit {
        lastOp.store(2)
        if(checkedBeforeReturn(value, checker, destroier)){
            synchronized(head.globalLock){
                head.insertNext(value)
                markReturned()
                PoolDiagnostics.onItemReturned()
            }
        }
        selfCheck()
    }
    public func append(value: T, checker: (T) -> Bool, destroier: (T) -> Unit): Unit {
        lastOp.store(3)
        if(checkedBeforeReturn(value, checker, destroier)){
            synchronized(head.globalLock){
                head.tail.insertPrev(value)
                markReturned()
                PoolDiagnostics.onItemReturned()
            }
        }
        selfCheck()
    }
    /**
     * 归还前的校验：`checker` 抛异常时**先按"校验不过"把这一项结清**（销毁 + 计数还原）再把异常抛出去。
     * 否则这一项既不算已归还、也没被销毁 ⇒ 永久挂在 `out` 上：池项凭空消失、池会越用越小（见 bug.md 7.12）。
     */
    private func checkedBeforeReturn(value: T, checker: (T) -> Bool, destroier: (T) -> Unit): Bool {
        var valid = false
        try {
            valid = checker(value)
        } catch (e: Exception) {
            discardItem(value, destroier)
            throw e
        }
        if(!valid){
            discardItem(value, destroier)
        }
        valid
    }
    /** 校验不过（或校验回调抛异常）：销毁该项并把「已借出」的计数还原，保证池项不会凭空消失。 */
    private func discardItem(value: T, destroier: (T) -> Unit): Unit {
        try {
            destroier(value)
        } catch (e: Exception) {
            // 销毁回调自己抛异常也不能影响记账：这里只记数，由上层日志体现（见 bug.md 7.12）
            PoolDiagnostics.onCallbackError()
        }
        PoolDiagnostics.onItemDestroyed()
        synchronized(head.globalLock){
            markReturned()
            s.fetchSub(1)
        }
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
                    PoolDiagnostics.onItemBorrowed()
                    taken = Some(x)
                }
            }
            if(let Some(x) <- taken){
                var valid = false
                try {
                    valid = checker(x)
                } catch (e: Exception) {
                    // 借出后的校验回调抛异常：这一项既没被拿走、也不算归还 ⇒ 会永久挂在 out 上
                    // （池项凭空消失）。自愈：按"校验不过"结清后再把异常抛给调用方（见 bug.md 7.12）。
                    discardItem(x, destroier)
                    throw e
                }
                if(valid){
                    selfCheck()
                    return x
                }else{
                    discardItem(x, destroier)
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
     * 自愈：`remove()` 一个项都取不到时的兜底（见 bug.md 7.2）。**队列本身是权威**，两种形态都按它校正：
     *
     * 1. **滞留项**：节点还挂在队列上、却不是 idle —— 它既不会被 `nextForGet` 取走，
     *    也不会再被 `prevForChecking` 挑中去清理 ⇒ 等于池记着它却永远用不上。
     *    判据只看「有没有 `check()` 在飞」：链表只在 `head.globalLock` 内改动，
     *    `ValueNode.check` 与 `check()` 的 finally 保证「`checkers` 归零时不该有非 idle 节点」
     *    ⇒ 此刻还存在的非 idle 节点必然是滞留的（不依赖计数，`out > 0` 也照样能救）。
     * 2. **计数脱钩**：`s` 与实际节点数不符（历史形态：「`s` 记着 1024 已满、队列里 0 个节点、
     *    也没有借出项」）。只在**没有借出项**时判：借出项本来就该「不在队列里」，
     *    有借出在途时 `s != nodes` 是正常的。
     */
    private func reconcileIfWedge(): Int64 {
        lastOp.store(6)
        synchronized(head.globalLock){
            if (checkers.load() != 0) {
                return 0                // 有 check 在飞：非 idle 节点是合法中间态，不动手
            }
            let (total, idles, checkings) = countNodes()
            let o = out.load()
            var healed = ''
            var actions = 0
            if (total > idles) {
                let revived = reviveNonIdle()
                PoolDiagnostics.onStrandedRevived(revived)
                actions += revived
                healed += ' stranded: nodes=${total} idle=${idles} checking=${checkings} revived=${revived}'
            }
            if (o == 0 && s.load() != total) {
                healed += ' bookkeeping: size=${s.load()} -> ${total}'
                s.store(total)
                PoolDiagnostics.onBookkeepingHealed()
                actions += 1
            }
            if (healed.size > 0) {
                println("WEDGE-HEAL]${healed}, out=${o}, lastOp=${DEQUE_OP_NAMES[lastOp.load()]}")
            }
            actions
        }
    }

    /**
     * **主动审计自愈**（巡检线程每轮调用，见 bug.md 7.12）：不必等"取不到项"才自愈，
     * 把滞留项与计数脱钩在空闲期就修掉，避免它们攒成"池记着满、却一个也取不出来"。
     * 返回本次校正的动作数（0 = 一切正常）。
     */
    public func audit(): Int64 {
        reconcileIfWedge()
    }

    /** 把仍挂在队列上、但不是 idle 的节点还原成 idle（滞留在 CHECKING 的池项，见 `reconcileIfWedge`）。 */
    private func reviveNonIdle(): Int64 {
        var revived = 0
        var node: ?Node<T> = head.nextForCount()
        while(let Some(n: ValueNode<T>) <- node){
            if(!n.idle){
                n.setIdle()
                revived++
            }
            node = n.nextForCount()
        }
        revived
    }
    public func check(running: () -> Bool, checker: (T) -> Bool, taskPusher: () -> Unit): Int64 {
        lastOp.store(5)
        var rm = 0
        checkers.fetchAdd(1)
        var pending: ?Node<T> = head.tail.prevForChecking()
        try {
            while(let Some(n: ValueNode<T>) <- pending){
                if(!running()){
                    break
                }
                pending = n.prevForChecking()
                // 摘节点与 s 递减必须在同一临界区（见 bug.md 7.4）：分属两处时会留下
                // 「节点已摘、s 未减」的中间态，被并发的不变量校验误判成记账脱钩。
                if(!n.check(checker, onRemoved: {=> s.fetchSub(1)})){
                    taskPusher()
                    rm++
                }
                sleep(Duration.Zero)
            }
        } finally {
            // 任何退出路径（`!running()`、checker 抛异常、taskPusher 抛异常）都必须把
            // 「已标记 CHECKING、还没被处理」的节点还原：停在 CHECKING 的节点既取不到、
            // 也不会再被 prevForChecking 挑中清理 = 永久丢一个池项（见 bug.md 7.2）。
            // 正在被 `n.check()` 处理的那个节点由 ValueNode.check 自己保证还原。
            if (let Some(n: ValueNode<T>) <- pending) {
                n.setIdle()
            }
            checkers.fetchSub(1)
        }
        rm
    }

    /**
     * 仅同包可见、**测试用**：把队首节点人为置于「滞留的 CHECKING」状态
     * （模拟 check 线程抛异常/被阻塞留下的现场），用于验证 `reconcileIfWedge()` 能把滞留项救回
     * （见 bug.md 7.2 与 SyncDeque_test.cj）。
     */
    func strandHeadForTest(): Bool {
        synchronized(head.globalLock){
            if (let Some(n: ValueNode<T>) <- head.nextForCount()) {
                n.setChecking()
                true
            } else {
                false
            }
        }
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
        if (let Some(ref) <- q.remove(refChecker(checker), refDestroier(destroier))) {
            // 引用类型的池项包的就是对象本身（WeakRef<Object>），只有值类型才被 Box 包一层；
            // 原来这里只匹配 WeakRef<Box<T>> ⇒ 引用类型会「节点已摘掉、却返回 None」：池项凭空丢失
            // （与 bug.md 7.2 的 `ValueNode.nextForGet` 同一类问题，弱引用池这条路径当前无人使用）。
            match (ref.value) {
                case Some(x: T) => return x
                case Some(x: Box<T>) => return x.value
                case _ => return None
            }
        }
        None
    }
    public func check(running: () -> Bool, checker: (T) -> Bool, taskPusher: () -> Unit): Int64 {
        q.check(running, refChecker(checker), taskPusher)
    }
    public func audit(): Int64 {
        q.audit()
    }
    public prop size: Int64 {
        get(){
            q.size
        }
    }
}
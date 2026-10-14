/*
Copyright (c) 2025 WuJingrun（吴京润）

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
package fountain::f_cache

import std.collection.{HashMap, ArrayList}
import std.collection.concurrent.LinkedBlockingQueue
import std.ref.{WeakRef, CleanupPolicy}
import std.time.DateTime
import std.sync.{Timer, AtomicBool}
import fountain::f_base.*
import fountain::f_collection.PriorityQueue

public class HeapCache<V> <: Resource where V <: Object {
    private let store: ConcHashMap<Priority<V>>
    private let closedFlag = AtomicBool(false)
    /**内部淘汰消费线程的句柄：close() 时向它发送取消请求，用例可通过 threadHandles() 等它结束*/
    private var evictionTask: Option<Future<Unit>> = None
    /**定时器句柄：close() 时 cancel，避免关闭后再触发一轮清扫*/
    private var timerHandle: Option<Timer> = None
    /**淘汰消费线程取元素的轮询间隔：只是「队列长期为空」时的兜底唤醒，close() 靠投递哨兵立即唤醒它*/
    private static let EVICTION_POLL_INTERVAL = Duration.millisecond * 100
    /**淘汰回调队列：元素 Some((key, value))；close() 投递 None 哨兵以立即唤醒阻塞中的消费线程*/
    private let evictionQueue = LinkedBlockingQueue<Option<(String, V)>>()

    public HeapCache(
        private let concurrencyLevel!: Int64 = DEFAULT_HEAP_CACHE_CONCURRENCY_LEVEL,
        private let maxLife!: Duration = DEFAULT_HEAP_CACHE_MAX_LIFE,
        private let maxSize!: Int64 = DEFAULT_HEAP_CACHE_MAX_SIZE,
        private let checkDuration!: Duration = DEFAULT_HEAP_CHECK_CHECK_DURATION,
        private let evictionCallback!: (String, V) -> Unit = {_, _ => ()}
    ) {
        if (maxLife < Duration.Zero || maxSize <= 0 || concurrencyLevel <= 0 || checkDuration <= Duration.Zero) {
            throw IllegalArgumentException(
                "maxLife must not be less than zero. maxSize and concurrencyLevel must be greater than zero. checkDuration must be greater than Duration.Zero. however current are ${maxLife}, ${maxSize}, ${concurrencyLevel}, ${checkDuration}")
        }
        this.store = ConcHashMap<Priority<V>>.create(concurrencyLevel: concurrencyLevel)
        startTimer()
        //进程退出时自动 close（close 会把已入队的淘汰回调投递完）；注册项只捕弱引用，
        //避免 f_base 的全局注册表把实例钉住 —— close() 之后对象可被 GC 回收
        let selfRef = WeakRef<HeapCache<V>>(this, CleanupPolicy.EAGER)
        ExitCallbacks.atExit(254, {=> if (let Some(cache) <- selfRef.value) { cache.close() }})
    }

    public static func builder(): HeapCacheBuilder<V> {
        return HeapCacheBuilder<V>()
    }
    private func onEviction(): LinkedBlockingQueue<Option<(String, V)>> {
        let q = evictionQueue
        evictionTask = Some(spawn {
            //按固定间隔取元素，并每轮检查一次取消请求（close() 会 future.cancel() 并投递哨兵）
            var stopping = false
            while (!stopping && !Thread.currentThread.hasPendingCancellation) {
                if (let Some(item) <- q.remove(EVICTION_POLL_INTERVAL)) {
                    match (item) {
                        //哨兵：close() 正在等本线程退出
                        case None => stopping = true
                        case Some((k, v)) => notifyEviction(k, v)
                    }
                }
            }
            //收到取消请求/哨兵后，把已入队的淘汰回调投递完再退出
            while (let Some(item) <- q.tryRemove()) {
                match (item) {
                    case Some((k, v)) => notifyEviction(k, v)
                    case None => ()
                }
            }
        })
        q
    }
    /**
     * 投递一次淘汰回调。回调抛出的异常在这里吞掉：
     * 否则消费线程会直接结束（之后所有淘汰回调静默失效），并且 close() 的 join（`f.get()`）会把异常重抛出来。
     * 需要上报的调用方请在回调内部自行捕获处理。
     */
    private func notifyEviction(k: String, v: V): Unit {
        try {
            evictionCallback(k, v)
        } catch (e: Exception) {
            ()
        }
    }
    /**仅供同包用例使用：内部线程句柄（HeapCache = 1 个淘汰消费线程），用来等待它结束*/
    func threadHandles(): ArrayList<Future<Unit>> {
        let handles = ArrayList<Future<Unit>>()
        if (let Some(f) <- evictionTask) {
            handles.add(f)
        }
        handles
    }
    private func startTimer() {
        let topVals = PriorityQueue<Priority<V>>.create<Priority<V>>(capacity: concurrencyLevel)
        let tops = HashMap<String, Priority<V>>()
        let q = onEviction()
        timerHandle = Some(Timer.after(checkDuration) {
            let iterator = (store.iterator() as ConcHashMapIterator<Priority<V>>).getOrThrow()
            checkTimeout(q)
            checkOverSize(topVals, tops, iterator, q)
            if (!closedFlag.load()) {
                checkDuration
            } else {
                None<Duration>
            }
        })
    }
    /**
     * 定时清扫（增量）：只扫「段级死亡时间下界已到」的段，稳定态下每 tick 只遍历段数组做一次原子读，
     * 不再全表逐条判过期。下界由 set/once/prolong/getOrCompute 保守登记（见各自调用点）。
     * 谓词在段锁内执行；关闭时清空全部条目（与原 removeIfLocked 的 closed 分支一致）。
     */
    private func checkTimeout(evictionQueue: LinkedBlockingQueue<Option<(String, V)>>): Unit {
        let now = DateTime.now()
        let nowNanos = now.toUnixTimeStamp().toNanoseconds()
        store.sweepExpired(nowNanos) {k, p =>
            if (closedFlag.load()) {
                (true, Int64.Max)
            } else {
                let (alive, deathNanos) = p.aliveAndDeathNanos(now)
                if (alive) {
                    (false, deathNanos)
                } else {
                    evictionQueue.add(Some((k, p.load())))
                    (true, Int64.Max)
                }
            }
        }
    }
    private func checkOverSize(
        topVals: PriorityQueue<Priority<V>>,
        tops: HashMap<String, Priority<V>>,
        iterator: ConcHashMapIterator<Priority<V>>,
        evictionQueue: LinkedBlockingQueue<Option<(String, V)>>
    ): Unit {
        let store = this.store
        let maxSize = this.maxSize
        let current = DateTime.now()
        while (store.size > maxSize && !closedFlag.load()) {
            let segmItrs = iterator.segmentIterators()
            var segmItrMap = HashMap<Int64, Iterator<(String, Priority<V>)>>()
            var i = 0
            for (segmItr in segmItrs where !closedFlag.load()) {
                if (let Some((k, p)) <- segmItr.next()) {
                    segmItrMap[i] = segmItr
                    p.index = i
                    topVals.add(p)
                }
                i++
            }
            while (store.size > maxSize && !closedFlag.load()) {
                var minIdx = -1
                if (let Some(p) <- topVals.remove()) {
                    store.remove(p.key)
                    minIdx = p.index
                    evictionQueue.add(Some((p.key, p.load())))
                }
                if (minIdx < 0 || store.size <= maxSize) {
                    break
                } else if (let Some(segm) <- segmItrMap.get(minIdx) && let Some(next) <- segm.next()) {
                    next[1].index = minIdx
                    topVals.add(next[1])
                }
            }
            while (let Some(p) <- topVals.remove() && !closedFlag.load()) {
                tops.add(p.key, p)
            }
        }
        for (p in tops.values() where !closedFlag.load()) { //不给Priority增加已删除标记，此处也不判断Priority是不是已被主动删除，因为这样做不节省时间
            p.updateLastChecked(current)
        }
        tops.clear()
    }
    private func expired(p: Priority<V>): Bool {
        DateTime.now() >= p.deathTime
    }

    /**关闭校验：关闭后调用任何公开操作都抛 IllegalStateException（isClosed/close 除外）*/
    private func ensureOpen(): Unit {
        if (closedFlag.load()) {
            throw IllegalStateException('heap cache is closed')
        }
    }
    public func get(key: String): Option<V> {
        ensureOpen()
        //单次加锁完成「判过期 + 记一次使用 + 取值」：原先 expired + load 要两次加锁、两次取时间
        match (store.get(key)) {
            case Some(p) => p.loadIfAlive()
            case _ => None<V>
        }
    }
    public func contains(key: String): Bool {
        ensureOpen()
        get(key).isSome()
    }
    public func once(key: String): Bool {
        ensureOpen()
        match (store.get(key)) {
            //与 get/contains 同口径：已过期（即使尚未被定时清扫）视为不存在
            case Some(p) where !expired(p) => onceLocked(key, p)
            case _ => false
        }
    }
    private func onceLocked(key: String, p: Priority<V>): Bool {
        let (r, dn) = synchronized(p.lock) {
            p.load()
            p.once = true
            //once=true 后死亡时间从 birth 起算（比 lastUsed 早），登记它可保证清扫不漏
            (true, (p.birthTime + p.maxLife).toUnixTimeStamp().toNanoseconds())
        }
        store.noteDeath(key, dn)
        r
    }
    public func prolong(key: String, life: Duration, once!: Bool = false): Bool {
        ensureOpen()
        match (store.get(key)) {
            //已过期条目不允许通过续期“复活”，调用方应改用 set 重建
            case Some(p) where !expired(p) => prolongLocked(key, p, life, once)
            case _ => false
        }
    }
    private func prolongLocked(key: String, p: Priority<V>, life: Duration, once: Bool): Bool {
        let (r, dn) = synchronized(p.lock) {
            p.load()
            p.maxLife = life
            p.once = once
            (true, (if (once) {
                p.birthTime + life
            } else {
                //lastUsed 刚被 p.load() 更新，取它算出的死亡时间精确且保守
                p.lastUsedTime + life
            }).toUnixTimeStamp().toNanoseconds())
        }
        store.noteDeath(key, dn)
        r
    }
    public func prolong(key: String, deathTime: DateTime): Bool {
        ensureOpen()
        match (store.get(key)) {
            case Some(p) where !expired(p) => prolongDeathAtLocked(key, p, deathTime)
            case _ => false
        }
    }
    private func prolongDeathAtLocked(key: String, p: Priority<V>, deathTime: DateTime): Bool {
        let r = synchronized(p.lock) {
            p.load()
            p.deathTime = deathTime
            p.once = true
            true
        }
        store.noteDeath(key, deathTime.toUnixTimeStamp().toNanoseconds())
        r
    }
    public func set(key: String, value: V, life!: Duration = this.maxLife, once!: Bool = false): ?V {
        ensureOpen()
        if (let Some(p) <- store.get(key)) {
            let (old, dn) = synchronized(p.lock) {
                let old = p.load()
                p.store(value)
                p.maxLife = life
                p.once = once
                //死亡时间：once 从 birth 算，否则从刚被更新的 lastUsed 算；登记给定时清扫做段级下界
                (old, (if (once) {
                    p.birthTime + life
                } else {
                    p.lastUsedTime + life
                }).toUnixTimeStamp().toNanoseconds())
            }
            store.noteDeath(key, dn)
            old
        } else {
            //新建条目同样按本次调用给出的寿命与一次性标记：life 的默认值就是缓存级 maxLife
            let created = Priority<V>(key, value, life, checkDuration, once)
            store.add(key, created)
            store.noteDeath(key, (created.birthTime + life).toUnixTimeStamp().toNanoseconds())
            Option<V>.None
        }
    }
    public func set(key: String, value: V, dieAt: DateTime): ?V {
        ensureOpen()
        set(key, value, life: dieAt - DateTime.now(), once: true)
    }
    public func getOrDefault(key: String, default: V): V {
        ensureOpen()
        return get(key) ?? default
    }
    public func getOrStore(key: String, value: V): V {
        ensureOpen()
        getOrCompute(key) {value}
    }
    public func getOrCompute(key: String, callable: () -> V): V {
        ensureOpen()
        getOrCompute(key) {
            (callable(), this.maxLife, false)
        }
    }
    public func getOrCompute(key: String, callable: () -> (V, DateTime)): V {
        ensureOpen()
        let note = DeathNote()
        let p = store.computeIfAbsent(key) {
            let data = callable()
            let created = Priority<V>(key, data[0], data[1] - DateTime.now(), checkDuration, true)
            //只有真的新建了条目才会走到这里；deathTime = birth + (dieAt - now) ≥ dieAt，登记 dieAt 保守
            note.nanos = data[1].toUnixTimeStamp().toNanoseconds()
            created
        }
        store.noteDeath(key, note.nanos)
        p.load()
    }
    public func getOrCompute(key: String, callable: () -> (V, Duration, Bool)): V {
        ensureOpen()
        let note = DeathNote()
        let p = store.computeIfAbsent(key) {
            let data = callable()
            let created = Priority<V>(key, data[0], data[1], checkDuration, data[2])
            //deathTime = birth + life（once）或 lastUsed + life，均不早于 birth + life
            note.nanos = (created.birthTime + data[1]).toUnixTimeStamp().toNanoseconds()
            created
        }
        store.noteDeath(key, note.nanos)
        p.load()
    }
    public func remove(key: String): Option<V> {
        ensureOpen()
        store.remove(key)?.load()
    }
    /**
     * 删除 predicate 返回 true 的条目。谓词在分段锁**之外**执行（两阶段：快照 → 锁外判定 → 按 key 删除），
     * 不会阻塞同段读写；代价是谓词看到的是快照，两阶段之间新写入的条目也可能被删除。
     */
    public func removeIf(predicate: (String, V) -> Bool): Unit {
        ensureOpen()
        store.removeIf {k: String, p: Priority<V> => predicate(k, p.load())}
    }
    public prop size: Int64 {
        get() {
            ensureOpen()
            store.size
        }
    }
    public func clear(): Unit {
        ensureOpen()
        store.clear()
    }
    /**
     * 停止内部线程（定时器 + 淘汰消费线程）并主动清空全部条目；**清空且内部线程结束后才返回**，可重复调用。
     * 关闭之后再调用任何操作（`get`/`set`/`size`/…）都会抛 `IllegalStateException`。
     */
    public func close(): Unit {
        if (closedFlag.load()) {
            return
        }
        closedFlag.store(true)
        if (let Some(t) <- timerHandle) {
            t.cancel()
        }
        //主动清空：不依赖定时器那一次 tick
        store.clear()
        if (let Some(f) <- evictionTask) {
            f.cancel()
            //投递哨兵唤醒可能正阻塞在 q.remove(EVICTION_POLL_INTERVAL) 的消费线程：
            //否则 close 要等它轮询超时（最长 ~100ms）
            evictionQueue.add(None<(String, V)>)
            //等消费线程把已入队的淘汰回调投递完并退出：close 返回即「清理完成」
            try {
                f.get()
            } catch (e: Exception) {
                //兜底：回调异常已在 notifyEviction 里吞掉，close 不应因内部线程而失败
            }
        }
    }
    public func isClosed(): Bool {
        closedFlag.load()
    }
}

/**getOrCompute 闭包内回写「本次新建条目的死亡时间」（命中时不写，保持 Int64.Max 使 noteDeath 直接短路）*/
class DeathNote {
    var nanos = Int64.Max
}

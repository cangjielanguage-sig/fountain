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
    /**淘汰消费线程取元素的轮询间隔：既保证 close() 能被及时感知，又不必忙等*/
    private static let EVICTION_POLL_INTERVAL = Duration.millisecond * 100

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
    private func onEviction(): LinkedBlockingQueue<(String, V)> {
        let q = LinkedBlockingQueue<(String, V)>()
        evictionTask = Some(spawn {
            //按固定间隔取元素，并每轮检查一次取消请求（close() 会 future.cancel()）
            while (!Thread.currentThread.hasPendingCancellation) {
                if (let Some((k, v)) <- q.remove(EVICTION_POLL_INTERVAL)) {
                    notifyEviction(k, v)
                }
            }
            //收到取消请求后，把已入队的淘汰回调投递完再退出
            while (let Some((k, v)) <- q.tryRemove()) {
                notifyEviction(k, v)
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
    private func checkTimeout(evictionQueue: LinkedBlockingQueue<(String, V)>): Unit {
        removeIfLocked {
            k, p => if (!closedFlag.load()) {
                if (expired(p)) {
                    evictionQueue.add((k, p.load()))
                    true
                } else {
                    false
                }
            } else {
                return true
            }
        }
    }
    private func checkOverSize(
        topVals: PriorityQueue<Priority<V>>,
        tops: HashMap<String, Priority<V>>,
        iterator: ConcHashMapIterator<Priority<V>>,
        evictionQueue: LinkedBlockingQueue<(String, V)>
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
                    evictionQueue.add((p.key, p.load()))
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
        match (store.get(key)) {
            case Some(p) where !expired(p) => p.load()
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
            case Some(p) where !expired(p) => synchronized(p.lock) {
                p.load()
                p.once = true
                true
            }
            case _ => false
        }
    }
    public func prolong(key: String, life: Duration, once!: Bool = false): Bool {
        ensureOpen()
        match (store.get(key)) {
            //已过期条目不允许通过续期“复活”，调用方应改用 set 重建
            case Some(p) where !expired(p) => synchronized(p.lock) {
                p.load()
                p.maxLife = life
                p.once = once
                true
            }
            case _ => false
        }
    }
    public func prolong(key: String, deathTime: DateTime): Bool {
        ensureOpen()
        match (store.get(key)) {
            case Some(p) where !expired(p) => synchronized(p.lock) {
                p.load()
                p.deathTime = deathTime
                p.once = true
                true
            }
            case _ => false
        }
    }
    public func set(key: String, value: V, life!: Duration = this.maxLife, once!: Bool = false): ?V {
        ensureOpen()
        if (let Some(p) <- store.get(key)) {
            synchronized(p.lock) {
                let old = p.load()
                p.store(value)
                p.maxLife = life
                p.once = once
                old
            }
        } else {
            //新建条目同样按本次调用给出的寿命与一次性标记：life 的默认值就是缓存级 maxLife
            store.add(key, Priority<V>(key, value, life, checkDuration, once))
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
        store.computeIfAbsent(key) {
            let data = callable()
            Priority<V>(key, data[0], data[1] - DateTime.now(), checkDuration, true)
        }.load()
    }
    public func getOrCompute(key: String, callable: () -> (V, Duration, Bool)): V {
        ensureOpen()
        store.computeIfAbsent(key) {
            let data = callable()
            Priority<V>(key, data[0], data[1], checkDuration, data[2])
        }.load()
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
    /**锁内版本：谓词廉价且需要「判定—删除」原子（定时清扫用）*/
    private func removeIfLocked(predicate: (String, Priority<V>) -> Bool): Unit {
        store.removeIfLocked(predicate)
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

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

import std.collection.concurrent.ArrayBlockingQueue
import std.sync.{AtomicBool, Mutex, Condition}
import fountain::f_base.ExitCallbacks
import fountain::f_pool.diagnostics.PoolDiagnostics
import fountain::f_pool.exception.PoolException

public interface KeyedObjectManager<K, V> {
    func create(key: K): V
    func check(key: K, value: V): Bool
    func destroy(key: K, value: V): Unit
    func clear(key: K, value: V): Unit {}
}
public class KeyPoolBuilder<K, V> where K <: Hashable & Equatable<K> {
    private var mode: Mode = Mode.Fifo
    private var initKeys: () -> ?K = {=> None}
    private var minSize: Int64 = 0
    private var maxSize: Int64 = 10
    private var totalSize: Int64 = maxSize
    private var idleTimeout: Duration = Duration.hour
    private var checkOnCreation: Bool = false
    private var checkOnBorrowing: Bool = true
    private var checkOnReturning: Bool = true
    private var clearOnReturning: Bool = false
    private var checkInterval: Duration = Duration.minute
    /** 池耗尽时 `get(timeout: Duration.Max)` 的等待上限；`Duration.Max` = 真无限等待（每轮仍让出 CPU）。 */
    private var maxWaiting: Duration = Duration.second * 30
    private var creator: ?(K) -> V = None
    private var checker: ?(K, V) -> Bool = None
    private var destroier: ?(K, V) -> Unit = None
    private var clear: (K, V) -> Unit = {_, _ =>}

    init(){}
    public func setMode(mode: Mode): This {
        this.mode = mode
        this
    }
    public func setInitKeys(initKeys: () -> ?K): This {
        this.initKeys = initKeys
        this
    }
    public func setinitKeys(initKeys: Iterable<K>): This{
        setInitKeys(initKeys.iterator().next)
    }
    public func setInitKeys(keys: Iterable<K>, initSizePerKey!: Int64 = 1){
        let idx = Box<Int64>(0)
        let key = Box<?K>(None)
        let itr = keys.iterator()
        setInitKeys{
            while(true){
                if (let Some(k) <- key.value && idx.value < initSizePerKey) {
                    idx.value++
                    return k
                } else if (let Some(k) <- itr.next()) {
                    idx.value = 0
                    key.value = k
                } else {
                    return None
                }
            }
            None
        }
    }
    public func setMinSize(minSize: Int64): This {
        this.minSize = minSize
        this
    }
    public func setMaxSize(maxSize: Int64): This {
        this.maxSize = maxSize
        this
    }
    public func setTotalSize(totalSize: Int64): This {
        this.totalSize = totalSize
        this
    }
    public func setIdleTimeout(idleTimeout: Duration): This {
        this.idleTimeout = idleTimeout
        this
    }
    public func setCheckOnCreation(checkOnCreation: Bool): This {
        this.checkOnCreation = checkOnCreation
        this
    }
    public func setCheckOnBorrowing(checkOnBorrowing: Bool): This {
        this.checkOnBorrowing = checkOnBorrowing
        this
    }
    public func setCheckOnReturning(checkOnReturning: Bool): This {
        this.checkOnReturning = checkOnReturning
        this
    }
    public func setClearOnReturning(clearOnReturning: Bool): This {
        this.clearOnReturning = clearOnReturning
        this
    }
    public func setCheckInterval(checkInterval: Duration): This {
        this.checkInterval = checkInterval
        this
    }
    /**
     * 池耗尽时 `get(timeout: Duration.Max)` 的等待上限：超过就 WARN 并返回 None（由调用方决定重试/失败）。
     * 传 `Duration.Max` 表示真无限等待 —— 实现每轮仍让出 CPU，不会是忙等。
     */
    public func setMaxWaiting(maxWaiting: Duration): This {
        this.maxWaiting = maxWaiting
        this
    }
    public func setCreator(creator: (K) -> V): This {
        this.creator = creator
        this
    }
    public func setChecker(checker: (K, V) -> Bool): This {
        this.checker = checker
        this
    }
    public func setDestroier(destroier: (K, V) -> Unit): This {
        this.destroier = destroier
        this
    }
    public func setClear(clear: (K, V) -> Unit): This {
        this.clear = clear
        this
    }
    public func setManager(manager: KeyedObjectManager<K, V>): This {
        setCreator(manager.create)
        setChecker(manager.check)
        setDestroier(manager.destroy)
        setClear(manager.clear)
        this
    }
    public func build(): KeyPool<K, V> {
        func toThrow(){
            throw PoolException('creator, checker and destroier must be set.')
        }
        KeyPool<K, V>(
            mode: mode,
            initKeys: initKeys,
            minSize: minSize,
            maxSize: maxSize,
            totalSize: totalSize,
            idleTimeout: idleTimeout,
            checkOnCreation: checkOnCreation,
            checkOnBorrowing: checkOnBorrowing,
            checkOnReturning: checkOnReturning,
            clearOnReturning: clearOnReturning,
            checkInterval: checkInterval,
            maxWaiting: maxWaiting,
            creator: creator ?? toThrow(),
            checker: checker ?? toThrow(),
            destroier: destroier ?? toThrow(),
            clear: clear)
    }
}
public class KeyPool<K, V> <: Resource where K <: Hashable & Equatable<K> {
    private let pool: IKeyPool<K, Ref<V>>
    private let tasks: ArrayBlockingQueue<PoolTask<K>>
    private let running = AtomicBool(true)
    /**
     * 构造完成标志：后台维护线程在构造函数返回前**不许碰 `this`**。
     * bug.md 7.12 那次 SIGSEGV 的栈顶是 `UnitKeyPool.size`（运行时泛型 MTable 空指针），
     * 一种可能是后台线程在对象尚未构造完（类型信息未就绪）时就开始使用它 ⇒ 这里加一道栅栏兜住这类风险。
     */
    private let constructed = AtomicBool(false)
    private let barrierMutex = Mutex()
    private let barrier = synchronized(barrierMutex){ barrierMutex.condition() }

    public KeyPool(
        mode!: Mode = Mode.Fifo,
        initKeys!: () -> ?K,
        private let minSize!: Int64 = 0,
        private let maxSize!: Int64 = 10,
        private let totalSize!: Int64 = maxSize,
        private let idleTimeout!: Duration = Duration.hour,
        private let checkOnCreation!: Bool = false,
        private let checkOnBorrowing!: Bool = true,
        private let checkOnReturning!: Bool = true,
        private let clearOnReturning!: Bool = false,
        private let checkInterval!: Duration = Duration.minute,
        /**
         * 池耗尽且 `get(timeout: Duration.Max)` 时的等待上限：超过它记 WARN 并返回 None；
         * 传 `Duration.Max` 表示真无限等待（实现仍每轮让出 CPU）。
         */
        private let maxWaiting!: Duration = Duration.second * 30,
        private let creator!: (K) -> V,
        private let checker!: (K, V) -> Bool,
        private let destroier!: (K, V) -> Unit,
        private let clear!: (K, V) -> Unit = {_, _ =>}
    ){
        this.pool = match(None<K>){
            case _: ?Unit => UnitKeyPool<K, Ref<V>>(mode, maxSize)
            case _ => BaseKeyPool<K, Ref<V>>(mode, maxSize)
        }
        tasks = ArrayBlockingQueue<PoolTask<K>>(totalSize)
        PoolDiagnostics.onPoolCreated()
        if (PoolDiagnostics.CRASH_DUMP_ON_FATAL) {
            // 首次建池装一次致命信号取证（幂等）：下次真出 SIGSEGV，至少能拿到池的运行统计（见 bug.md 7.12）
            PoolDiagnostics.installCrashHandler()
        }
        startCheckingSchedule()
        startCreationSchedule()
        while(let Some(k) <- initKeys()){
            tryAddTask(k)
        }
        ExitCallbacks.atExit(254, close)
        // 必须是构造函数的最后一步：放行两个后台线程（见 constructed 的说明）
        synchronized(barrierMutex){
            constructed.store(true)
            barrier.notifyAll()
        }
    }
    /** 后台线程等"构造完成"再动 `this`；构造一完成即被唤醒，无固定延迟（见 `constructed` 的说明）。 */
    private func waitConstructed(): Unit {
        if (constructed.load()) {
            return
        }
        synchronized(barrierMutex){
            if (!constructed.load()) {
                barrier.wait()
            }
        }
    }
    public init(
        mode!: Mode = Mode.Fifo,
        initKeys!: () -> ?K,
        minSize!: Int64 = 0,
        maxSize!: Int64 = 10,
        totalSize!: Int64 = maxSize,
        idleTimeout!: Duration = Duration.hour,
        checkOnCreation!: Bool = false,
        checkOnBorrowing!: Bool = true,
        checkOnReturning!: Bool = true,
        clearOnReturning!: Bool = false,
        checkInterval!: Duration = Duration.minute,
        maxWaiting!: Duration = Duration.second * 30,
        manager!: KeyedObjectManager<K, V>
    ){
        this(
            mode: mode,
            initKeys: initKeys,
            minSize: minSize,
            maxSize: maxSize,
            totalSize: totalSize,
            idleTimeout: idleTimeout,
            checkOnCreation: checkOnCreation,
            checkOnBorrowing: checkOnBorrowing,
            checkOnReturning: checkOnReturning,
            clearOnReturning: clearOnReturning,
            checkInterval: checkInterval,
            maxWaiting: maxWaiting,
            creator: manager.create,
            checker: manager.check,
            destroier: manager.destroy,
            clear: manager.clear
        )
    }
    public static func builder(): KeyPoolBuilder<K, V> {
        KeyPoolBuilder<K, V>()
    }
    private func doCheck(k: K, v: V, checker: (K, V) -> Bool): Bool {
        try{
            checker(k, v)
        }catch(e: Exception){
            logger.warn('error on checking', e)
            false
        }
    }
    private func startCheckingSchedule() {
        if(checkInterval <= Duration.Zero){
            return
        }
        spawn {
            waitConstructed()
            // 看护循环：巡检线程**不允许**静默退出 —— 一旦退出，空闲回收、minSize 补足、审计自愈
            // 都会永久停摆（见 bug.md 7.12）。异常或意外退出都记 WARN 并重开。
            while(running.load()){
                try{
                    checkingLoop()
                }catch(e: Exception){
                    logger.warn('error on pool checking schedule', e)
                }
                if(running.load()){
                    PoolDiagnostics.onScheduleRestart()
                    logger.warn('pool checking schedule exited unexpectedly, restarting it')
                    sleep(Duration.second)
                }
            }
        }
    }
    /** 巡检的一轮循环（拆出来便于看护重开）。 */
    private func checkingLoop(): Unit {
        while(running.load()){
            sleep(checkInterval)
            if(!running.load()){
                return
            }
            pool.check({=> running.load()}, {k, r => 
                var valid = !r.isIdleTimeout() && if(let Some(v) <- r.get()){
                    doCheck(k, v, checker)
                }else{
                    false
                }
                if(!valid){
                    if(let Some(v) <- r.get()){
                        doDestroy(k, v, destroier)
                    }
                }
                valid
            }){k => tryAddTask(k)}
            for ((k, s) in pool.entries() where s < minSize) {
                sleep(Duration.Zero)
                tryAddTask(k)
            }
            // 巡检顺带审计自愈（见 bug.md 7.2 / 7.12）：滞留项与计数脱钩在空闲期就修掉，
            // 不必等某个 get 取不到项才暴露。
            let healed = pool.audit()
            PoolDiagnostics.onAuditRound()
            if(healed > 0){
                logger.warn('pool audit healed ${healed} anomaly(ies), size=${pool.size}')
            }
        }
    }
    private func tryAddTask(key: K){
        let task = PoolTask<K>(key)
        if(tasks.tryAdd(task)){
            task
        }else{
            None<PoolTask<K>>
        }
    }
    private func startCreationSchedule() {
        spawn {
            waitConstructed()
            // 看护循环：创建线程一旦退出，池就再也补不回池项（`get` 只会等到 maxWaiting 超时），
            // 所以同样不许静默退出（见 bug.md 7.12）。
            while(running.load()){
                try{
                    creationLoop()
                }catch(e: Exception){
                    logger.warn('error on pool creation schedule', e)
                }
                if(running.load()){
                    PoolDiagnostics.onScheduleRestart()
                    logger.warn('pool creation schedule exited unexpectedly, restarting it')
                    sleep(Duration.second)
                }
            }
        }
    }
    /** 创建线程的一轮循环（拆出来便于看护重开）。 */
    private func creationLoop(): Unit {
        while(running.load() && let task <- tasks.remove()){
            while(running.load() && pool.size < totalSize && let k <- task.key && pool.keyedSize(k) < maxSize){
                try {
                    let object = creator(k)
                    if (checkOnCreation && !doCheck(k, object, checker)){
                        doDestroy(k, object, destroier)
                    } else {
                        pool.add(k, ref(k, object))
                        break
                    }
                }catch(e: Exception){
                    PoolDiagnostics.onCallbackError()
                    logger.warn('error on creating', e)
                }
                sleep(Duration.Zero)
                continue
            }
            task.notify()
        }
    }
    private func ref(key: K, object: V){
        Ref<V>(object, idleTimeout){object => destroier(key, object)}
    }
    public func isClosed(): Bool {
        !running.load()
    }
    public func close(): Unit {
        running.store(false)
        while(let Some(_) <- tasks.tryRemove()){}
        pool.destroy{k, r => 
            if(let Some(v) <- r.get()){
                doDestroy(k, v, destroier)
            }
        }
        PoolDiagnostics.onPoolClosed()
    }
    private func doDestroy(k: K, v: V, destroier: (K, V) -> Unit){
        try{
            destroier(k, v)
        }catch(e: Exception){
            logger.warn('error on destroying', e)
        }
    }
    private func keyedDestroy(key: K, ref: Ref<V>): Unit {
        if(let Some(v) <- ref.get()){
            doDestroy(key, v, destroier)
        }
    }
    private func keyedCheck(toCheck: Bool, key: K, ref: Ref<V>){
        if(toCheck){
            if(let Some(v) <- ref.get()){
                doCheck(key, v, checker)
            }else{
                false
            }
        }else{
            true
        }
    }
    /**
     * 本轮「等新建池项」愿意等多久。
     *
     * - 有限上限（默认 30s）：给出剩余等待预算，行为与原实现一致 —— 新建出来会立刻把调用方唤醒；
     * - 真无限等待（`maxWaiting == Duration.Max`）：给一个固定分片。既避免 `MonoTime + Duration.Max` 溢出，
     *   也不至于长时间睡着而看不到 `running` 变化。
     */
    private func waitChunk(waitStart: MonoTime): Duration {
        if (maxWaiting == Duration.Max) {
            return Duration.second
        }
        let remain = waitStart + maxWaiting - MonoTime.now()
        if (remain <= Duration.Zero) {
            Duration.Zero
        } else {
            remain
        }
    }
    public func get(key: K, timeout!: Duration = Duration.Max): ?V {
        func keyedCheck(key: K, ref: Ref<V>){
            this.keyedCheck(checkOnBorrowing, key, ref)
        }
        if(timeout <= Duration.Zero){
            if(running.load() && let Some(r) <- pool.get(key, keyedCheck, keyedDestroy) && let Some(v) <- r.get()){
                return v
            }
        }else if(timeout == Duration.Max){
            // 注意：原实现在「池已满且取不到空闲项」时是 while(running.load()) 无 sleep 忙等，
            // 既 100% 占用一个核、又会**无日志地永久挂住**调用者（见 .autocode/bug.md 六）。
            // 这里保持「等待」语义，但每轮让出 CPU，并在超过上限后告警放弃（返回 None），
            // 由上层决定重试或失败，避免静默挂起。
            let waitStart = MonoTime.now()
            while(running.load()) {
                if (let Some(r) <- pool.get(key, keyedCheck, keyedDestroy) && let Some(v) <- r.get()) {
                    return v
                }else if (pool.size < totalSize && pool.keyedSize(key) < maxSize && 
                    let Some(x) <- tryAddTask(key) && 
                    let remain <- waitChunk(waitStart) && (remain <= Duration.Zero || !x.wait(remain))) {
                    break
                }
                if (maxWaiting != Duration.Max && MonoTime.now() - waitStart >= maxWaiting) {
                    logger.warn(
                        'key pool exhausted but no idle element: size=${pool.size}/${totalSize}, keyedSize=${pool.keyedSize(key)}/${maxSize}, waited ${maxWaiting}, give up')
                    break
                }
                sleep(Duration.millisecond)
            }
        }else{
            let start = MonoTime.now()
            while(running.load() && MonoTime.now() < start + timeout) {
                if (let Some(r) <- pool.get(key, keyedCheck, keyedDestroy) && let Some(v) <- r.get()) {
                    return v
                }else if (pool.size < totalSize && pool.keyedSize(key) < maxSize && 
                    let Some(x) <- tryAddTask(key) && 
                    let wait <- start + timeout - MonoTime.now() && (wait <= Duration.Zero || !x.wait(wait))) {
                    break
                }
            }
        }
        None
    }
    public func giveBack(key: K, object: V): Unit {
        if(!running.load()){
            return doDestroy(key, object, destroier)
        }
        func keyedCheck(key: K, ref: Ref<V>){
            this.keyedCheck(checkOnReturning, key, ref)
        }
        if(clearOnReturning){
            clear(key, object)
        }
        pool.giveBack(key, ref(key, object), keyedCheck, keyedDestroy)
    }
    prop size: Int64{
        get(){
            pool.size
        }
    }
    func checkSize(): Bool {
        var s = 0
        for((_, ps) in pool.entries()){
            s += ps
        }
        s == size
    }
}
private struct PoolTask<K> where K <: Hashable & Equatable<K> {
    private let mutex = Mutex()
    private let condition = synchronized(mutex){
        mutex.condition()
    }
    PoolTask(let key: K){}
    func wait(timeout: Duration): Bool {
        synchronized(mutex){
            condition.wait(timeout: timeout)
        }
    }
    func notify(): Unit {
        synchronized(mutex){
            condition.notify()
        }
    }
}
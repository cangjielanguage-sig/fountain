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
import std.sync.{AtomicBool, AtomicInt64, Mutex, Condition}
import fountain::f_base.ExitCallbacks
import fountain::f_pool.diagnostics.PoolDiagnostics
import fountain::f_pool.exception.PoolException

/**
 * 「创建任务」队列的容量上限：它只是给创建线程传「给某键建一个池项」的纸条，槽位数**不必**等于池容量 ——
 * `ArrayBlockingQueue.init(capacity)` 会**立即**按容量分配数组与状态位（std 源码 `array_blocking_queue.cj:68-78`），
 * 拿池容量当容量时：`maxSize = Int64.Max`（`ArrayPool`/`ArrayListPool` 的默认值）直接 OOM、
 * 5e6 时白付 80MB 堆。队列满时 `tryAddTask` 返回 false、等待者下一轮再试，不影响正确性
 * （见 .autocode/bugs/bug-pool.md §2.3 `POOL-8`）。
 */
private const CREATE_TASK_QUEUE_CAP: Int64 = 1024

/** 池容量 → 任务队列容量：夹在 `[1, CREATE_TASK_QUEUE_CAP]`（`ArrayBlockingQueue` 的容量必须为正）。 */
private func createTaskQueueCapacity(total: Int64): Int64 {
    if (total < 1) {
        1
    } else if (total > CREATE_TASK_QUEUE_CAP) {
        CREATE_TASK_QUEUE_CAP
    } else {
        total
    }
}
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
    /** 「给某键建一个池项」的任务队列（元素就是键，历史实现里元素是每等待者一个的 `PoolTask`）。 */
    private let tasks: ArrayBlockingQueue<K>
    private let running = AtomicBool(true)
    /**
     * 内部维护线程的句柄：`close()` 用 `cancel()` 向它们发取消请求（协作式，不强制停线程）。
     * 线程自己的循环每轮判 `Thread.currentThread.hasPendingCancellation`，配合
     * `tasks.remove(timeout: Duration.second)` 这种**带超时**的出队 ⇒ 关池后最迟 1s 内退出
     * （见 .autocode/bugs/bug-pool.md §2.2 `POOL-7`：原来是无超时 `remove()`，线程永久 park）。
     * 注：`ArrayBlockingQueue` 只有 `tryRemove()`（非阻塞）与 `remove(timeout: Duration)`（带超时）两个重载，
     * 没有 `tryRemove(timeout:)` —— 这里用的是后者。
     */
    private var creationThread: ?Future<Unit> = None
    private var checkingThread: ?Future<Unit> = None
    /**
     * 「等待池项」的通道：池耗尽时 `get` park 在这里，由**创建完成 / 归还 / 关停**三处唤醒 ——
     * 不再有 1ms 轮询（见 .autocode/bugs/bug-pool.md §1.2 `POOL-2`、§2.1 `POOL-6`）。
     * `available` 是「池状态可能变好」的纪元号：`wakeWaiters()` 先加它再通知，
     * 等待者登记后若发现纪元变了就不 park（关掉 notify 早于 park 的丢唤醒窗口）；
     * `waiters` 只用于省掉无人等待时的空通知。
     */
    private let waitMutex = Mutex()
    private let waitCond = synchronized(waitMutex){ waitMutex.condition() }
    private let available = AtomicInt64(0)
    private let waiters = AtomicInt64(0)
    /**
     * 构造完成标志：后台维护线程在构造函数返回前**不许碰 `this`**。
     * 归档报告 7.12（`.autocode/bugs/bug-archived-on-20261004.md`）那次 SIGSEGV 的栈顶是 `UnitKeyPool.size`（运行时泛型 MTable 空指针），
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
        // 任务队列容量与池容量解耦（夹在 [1, 1024]）：见 createTaskQueueCapacity 的说明（§2.3 POOL-8）
        tasks = ArrayBlockingQueue<K>(createTaskQueueCapacity(totalSize))
        PoolDiagnostics.onPoolCreated()
        // 把池内的常规告警接到 f_log（幂等：应用若已用 redirectWarningsTo 接管，这里不会覆盖）
        PoolDiagnostics.installDefaultHooks(
            {message => logger.warn(message)},
            {message => logger.error(message)})
        // 进程退出时若发生过异常，落一条统计（健康时静默）——SIGSEGV 现场拿不到，这是可用的替代（见 .autocode/bugs/bug-archived-on-20261004.md 7.12）
        PoolDiagnostics.installShutdownReport()
        if (PoolDiagnostics.CRASH_DUMP_ON_FATAL) {
            // 首次建池装一次致命信号取证（幂等）：下次真出 SIGSEGV，至少能拿到池的运行统计（见 .autocode/bugs/bug-archived-on-20261004.md 7.12）
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
        checkingThread = spawn {
            waitConstructed()
            // 看护循环：巡检线程**不允许**静默退出 —— 一旦退出，空闲回收、minSize 补足、审计自愈
            // 都会永久停摆（见 .autocode/bugs/bug-archived-on-20261004.md 7.12）。异常或意外退出都记 WARN 并重开。
            // 每轮判「取消请求 + running」：`close()` 之后静默退出，而不是被当成异常重开（见 §2.2 POOL-7）。
            while(!Thread.currentThread.hasPendingCancellation && running.load()){
                try{
                    checkingLoop()
                }catch(e: Exception){
                    if (Thread.currentThread.hasPendingCancellation || !running.load()) {
                        break
                    }
                    logger.warn('error on pool checking schedule', e)
                }
                if(!Thread.currentThread.hasPendingCancellation && running.load()){
                    PoolDiagnostics.onScheduleRestart()
                    logger.warn('pool checking schedule exited unexpectedly, restarting it')
                    sleep(Duration.second)
                }
            }
        }
    }
    /** 巡检的一轮循环（拆出来便于看护重开）。 */
    private func checkingLoop(): Unit {
        while(!Thread.currentThread.hasPendingCancellation && running.load()){
            sleep(checkInterval)
            if(Thread.currentThread.hasPendingCancellation || !running.load()){
                return
            }
            pool.check({=> running.load()}, {k, r => 
                var valid = !r.isIdleTimeout() && if(let Some(v) <- r.get()){
                    doCheck(k, v, checker)
                }else{
                    false
                }
                if(!valid){
                    // take()：显式销毁过的池项其 Ref 已空，终结器不会再销毁第二次（见 .autocode/bugs/bug-pool.md §1.1）
                    if(let Some(v) <- r.take()){
                        doDestroy(k, v, destroier)
                    }
                }
                valid
            }){k => tryAddTask(k)}
            for ((k, s) in pool.entries() where s < minSize) {
                sleep(Duration.Zero)
                tryAddTask(k)
            }
            // 巡检顺带审计自愈（见 .autocode/bugs/bug-archived-on-20261004.md 7.2 / 7.12）：滞留项与计数脱钩在空闲期就修掉，
            // 不必等某个 get 取不到项才暴露。
            // 这里统一打一条 WARN（含 size 校正前后的值），底层各层只负责"修 + 返回动作数"，不重复打日志。
            let sizeBefore = pool.size
            let healed = pool.audit()
            PoolDiagnostics.onAuditRound()
            if(healed > 0){
                logger.warn('pool audit healed ${healed} anomaly(ies): size ${sizeBefore} -> ${pool.size}, ${PoolDiagnostics.snapshot()}')
            }
            // 异常计数一旦有变化就落一条统计（健康时静默）：崩溃前"最后已知状态"靠这条留在日志里（见 .autocode/bugs/bug-archived-on-20261004.md 7.12）
            PoolDiagnostics.reportIfChanged('pool audit')
            // 本轮可能销毁了失效项（腾出额度）⇒ 唤醒等待者去重试「建一个」（见 §1.2 POOL-2）
            wakeWaiters()
        }
    }
    /**
     * 唤醒所有等池项的 `get`：先推进 `available` 纪元（等待者据此避免「通知早于 park」的丢唤醒），
     * 再在有人等待时通知。创建完成、归还、关停、巡检腾额度四处都会调它。
     */
    private func wakeWaiters(): Unit {
        available.fetchAdd(1)
        if(waiters.load() <= 0){
            return
        }
        synchronized(waitMutex){
            waitCond.notifyAll()
        }
    }
    /** 把「给某键建一个池项」的任务入队；队列满/已关停返回 false（调用方下一轮再试）。 */
    private func tryAddTask(key: K): Bool {
        tasks.tryAdd(key)
    }
    private func startCreationSchedule() {
        creationThread = spawn {
            waitConstructed()
            // 看护循环：创建线程一旦退出，池就再也补不回池项（`get` 只会等到 maxWaiting 超时），
            // 所以同样不许静默退出（见 .autocode/bugs/bug-archived-on-20261004.md 7.12）。
            // 每轮判「取消请求 + running」：`close()` 之后静默退出（见 §2.2 POOL-7）。
            while(!Thread.currentThread.hasPendingCancellation && running.load()){
                try{
                    creationLoop()
                }catch(e: Exception){
                    if (Thread.currentThread.hasPendingCancellation || !running.load()) {
                        break
                    }
                    logger.warn('error on pool creation schedule', e)
                }
                if(!Thread.currentThread.hasPendingCancellation && running.load()){
                    PoolDiagnostics.onScheduleRestart()
                    logger.warn('pool creation schedule exited unexpectedly, restarting it')
                    sleep(Duration.second)
                }
            }
        }
    }
    /** 创建线程的一轮循环（拆出来便于看护重开）。 */
    private func creationLoop(): Unit {
        // 每轮判「取消请求」，出队用**带超时**的 `remove(Duration.second)`（`ArrayBlockingQueue` 只有
        // `tryRemove()` 非阻塞版与 `remove(timeout: Duration)` 带超时版，没有 `tryRemove(timeout:)`）。
        // 池一关（`close()` 发取消请求）本线程最迟 1s 内退出；原来是无超时 `remove()`，
        // 空队列上永久 park，`close()` 唤不醒它（见 .autocode/bugs/bug-pool.md §2.2 POOL-7）。
        // 超时返回 None 只是「这一秒没任务」⇒ 回到循环顶再判一次取消/关停，不是异常退出。
        while(!Thread.currentThread.hasPendingCancellation && running.load()){
            if (let Some(k) <- tasks.remove(Duration.second)) {
                while(!Thread.currentThread.hasPendingCancellation && pool.size < totalSize && pool.keyedSize(k) < maxSize){
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
                // 处理完一条任务就唤醒等待者：建成了他要立刻来取，没建成（额度满）他也要复查一次（见 §1.2 POOL-2）
                wakeWaiters()
            }
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
        // 给两个内部维护线程发取消请求（协作式）：它们的循环每轮判 `hasPendingCancellation`
        // + 带超时出队 ⇒ 最迟 1s 内退出，不再永久 park（见 §2.2 POOL-7）
        if (let Some(t) <- creationThread) {
            t.cancel()
        }
        if (let Some(t) <- checkingThread) {
            t.cancel()
        }
        // 等待者必须立刻看到 running=false 并返回 None，不能让他们 park 到预算耗尽（见 §2.1 POOL-6）
        wakeWaiters()
        while(let Some(_) <- tasks.tryRemove()){}
        pool.destroy{k, r => 
            // take()：显式销毁过的池项其 Ref 已空，终结器不会再销毁第二次（见 .autocode/bugs/bug-pool.md §1.1）
            if(let Some(v) <- r.take()){
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
        // take()：借出/归还校验不过而销毁时也把 Ref 取空，避免终结器二次销毁（见 .autocode/bugs/bug-pool.md §1.1）
        if(let Some(v) <- ref.take()){
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
     * park 等「池项可借 / 池已关停」的通知（**不轮询**，见 .autocode/bugs/bug-pool.md §1.2 `POOL-2`）。
     *
     * 调用前调用方已把自己要的池项任务入队；创建完成、`giveBack`、`close`、巡检腾出额度四处都会 `wakeWaiters`。
     * 被唤醒不代表一定有事发生（可能归还的项被别人抢走）—— 调用方醒来后必须自己复查池与 `running`。
     *
     * 丢唤醒说明：`wakeWaiters` 先推进 `available` 纪元再通知；等待者「登记 `waiters` → 读纪元 →
     * 持 `waitMutex` 再确认」——纪元已变就直接返回不 park，因此「通知发生在 park 之前」不会丢。
     */
    private func waitItem(remain: Duration): Unit {
        waiters.fetchAdd(1)
        let seen = available.load()
        try {
            if (available.load() != seen) {
                return
            }
            synchronized(waitMutex){
                // 同一把锁下再确认一次：纪元推进是无锁的，但通知必须拿这把锁
                // ⇒ 只要纪元没变，park 之后的那个通知一定能拿到锁把我们叫醒。
                if (available.load() != seen) {
                    return
                }
                if (remain == Duration.Max) {
                    waitCond.wait()                  // 真无限等待：只靠通知（close 也会通知）
                } else {
                    waitCond.wait(timeout: remain)
                }
            }
        } finally {
            waiters.fetchSub(1)
        }
    }
    public func get(key: K, timeout!: Duration = Duration.Max): ?V {
        func keyedCheck(key: K, ref: Ref<V>){
            this.keyedCheck(checkOnBorrowing, key, ref)
        }
        if(timeout <= Duration.Zero){
            // 借出从 Ref 里 take()：借出即把值取空，终结器就不会在借用方手里销毁这一项
            // （见 .autocode/bugs/bug-pool.md §1.1）。
            if(running.load() && let Some(r) <- pool.get(key, keyedCheck, keyedDestroy) && let Some(v) <- r.take()){
                return v
            }
        }else{
            /**
             * 两条等待路径合成一条：
             * - `timeout == Duration.Max`（默认）：等待上限是池参数 `maxWaiting`（它传 `Duration.Max` = 真无限）；
             * - 有限 `timeout`：等待上限就是它。
             * 两条都在**通知上 park**：不再 1ms 轮询（`POOL-2`），也不会因为「分片超时」提前放弃（`POOL-5`）。
             */
            let waitStart = MonoTime.now()
            let limit = if (timeout == Duration.Max) { maxWaiting } else { timeout }
            let infinite = limit == Duration.Max
            while(running.load()) {
                if (let Some(r) <- pool.get(key, keyedCheck, keyedDestroy) && let Some(v) <- r.take()) {
                    return v
                }
                // 还有额度就把「建一个」入队；建好由创建线程 wakeWaiters 唤醒（被别的键/线程唤醒也会重试）
                if (pool.size < totalSize && pool.keyedSize(key) < maxSize) {
                    tryAddTask(key)
                }
                let remain = if (infinite) { Duration.Max } else { limit - (MonoTime.now() - waitStart) }
                if (remain != Duration.Max && remain <= Duration.Zero) {
                    break
                }
                waitItem(remain)
            }
            if (running.load() && !infinite && timeout == Duration.Max) {
                // 只有「Duration.Max + 有限 maxWaiting」档告警放弃（与原实现/README 口径一致）
                logger.warn(
                    'key pool exhausted but no idle element: size=${pool.size}/${totalSize}, keyedSize=${pool.keyedSize(key)}/${maxSize}, waited ${maxWaiting}, give up')
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
        // 与 close() 交错时本项可能是在「清池」之后才入池的 ⇒ 取出来销毁，不让它留在一个已关闭的池里
        // （既没人取也没人销毁；池对象还被 atExit 回调长期持有，见 §2.1 POOL-6 / §2.8 POOL-13）
        if(!running.load()){
            if (let Some(r) <- pool.get(key, {_, _ => true}, keyedDestroy) && let Some(v) <- r.take()) {
                doDestroy(key, v, destroier)
            }
        }
        // 唤醒等池项的 get（见 §1.2 POOL-2）
        wakeWaiters()
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

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
import std.env
import std.sync.{AtomicBool, Mutex, Condition}
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
        startCheckingSchedule()
        startCreationSchedule()
        while(let Some(k) <- initKeys()){
            tryAddTask(k)
        }
        env.atExit(close)
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
            while(running.load()){
                sleep(checkInterval)
                try{
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
                }catch(e: Exception){
                    logger.warn('error on pool checking schedule', e)
                }
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
        let start = MonoTime.now()
        spawn {
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
                        logger.warn('error on creating', e)
                    }
                    sleep(Duration.Zero)
                    continue
                }
                task.notify()
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
        while(let Some(_) <- tasks.tryRemove()){}
        pool.destroy{k, r => 
            if(let Some(v) <- r.get()){
                doDestroy(k, v, destroier)
            }
        }
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
    public func get(key: K, timeout!: Duration = Duration.Max): ?V {
        func keyedCheck(key: K, ref: Ref<V>){
            this.keyedCheck(checkOnBorrowing, key, ref)
        }
        if(timeout <= Duration.Zero){
            if(running.load() && let Some(r) <- pool.get(key, keyedCheck, keyedDestroy) && let Some(v) <- r.get()){
                return v
            }
        }else if(timeout == Duration.Max){
            while(running.load()) {
                if (let Some(r) <- pool.get(key, keyedCheck, keyedDestroy) && let Some(v) <- r.get()) {
                    return v
                }else if (pool.size < totalSize && pool.keyedSize(key) < maxSize && 
                    let Some(x) <- tryAddTask(key) && !x.wait(Duration.Max)) {
                    break
                }
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
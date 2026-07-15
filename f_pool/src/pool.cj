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
package fountain::f_pool

import std.collection.concurrent.ArrayBlockingQueue
import std.env
import std.sync.{AtomicInt64, AtomicBool}
import std.time.MonoTime
import fountain::f_log.LoggerFactory

public interface PooledManager<T> {
    func create(): T
    func check(object: T): Bool
    func destroy(object: T): Unit
    func clear(object: T): Unit{}
}
/**
 * 本类型无法分辨返还的实例是不是从Pool借出去的，也无法分辨借出实例的Pool跟返回实例的Pool是不是同一个，因此调用giveBack返还实例的时候，如果返回时检查失败了一定会销毁返还的实例，池维护的实例数随之减1。
 */
public class Pool<T> <: Resource {
    private static let log = LoggerFactory.getLogger('fountain::f_pool.Pool')
    private let queue: ArrayBlockingQueue<(T, MonoTime)>
    private let tasks: ArrayBlockingQueue<Unit>
    private let size = AtomicInt64(0)
    private let running = AtomicBool(true)
    public Pool(
        private let initSize!: Int64 = 0,
        private let minSize!: Int64 = 0,
        private let maxSize!: Int64 = 10,
        private let idleTimeout!: Duration = Duration.hour,
        private let checkOnCreation!: Bool = false,
        private let checkOnBorrowing!: Bool = true,
        private let checkOnReturning!: Bool = true,
        private let clearOnReturning!: Bool = false,
        private let checkInterval!: Duration = Duration.minute,
        private let creator!: () -> T,
        private let checker!: (T) -> Bool,
        private let destroier!: (T) -> Unit,
        private let clear!: (T) -> Unit = {_ =>}
    ) {
        queue = ArrayBlockingQueue<(T, MonoTime)>(maxSize)
        tasks = ArrayBlockingQueue<Unit>(maxSize)
        startCheckingSchedule()
        startCreationSchedule()
        for (_ in 0..initSize) {
            tasks.add(())
        }
        env.atExit(close)
    }
    public init(
        initSize!: Int64 = 0,
        minSize!: Int64 = 0,
        maxSize!: Int64 = 10,
        idleTimeout!: Duration = Duration.hour,
        checkOnCreation!: Bool = false,
        checkOnBorrowing!: Bool = true,
        checkOnReturning!: Bool = true,
        checkInterval!: Duration = Duration.minute,
        manager!: PooledManager<T>
    ) {
        this(initSize: initSize, minSize: minSize, maxSize: maxSize, idleTimeout: idleTimeout,
            checkOnCreation: checkOnCreation, checkOnBorrowing: checkOnBorrowing, checkOnReturning: checkOnReturning,
            checkInterval: checkInterval, creator: manager.create, checker: manager.check, destroier: manager.destroy,
            clear: manager.clear)
    }
    public static func builder(): PoolBuilder<T> {
        PoolBuilder<T>()
    }
    private func startCheckingSchedule() {
        if (checkInterval <= Duration.Zero) {
            return
        }
        func doDestroy(o: T){
            try{
                destroy(o, true)
                if (this.size.load() < minSize) {
                    tasks.tryAdd(())
                }
            }catch(e: Exception){
                log.warn('Pool destroying on checking schedule', e)
            }
        }
        spawn {
            while (running.load()) {
                var i = 0
                while (running.load() && i < this.size.load() && let (o, t) <- queue.remove()) {
                    i++
                    try {
                        if ((idleTimeout > Duration.Zero && MonoTime.now() - t >= idleTimeout) || !checker(o)) {
                            doDestroy(o)
                        } else {
                            queue.add((o, t))
                        }
                    } catch (e: Exception) {
                        log.warn('Pool checking schedule', e)
                        doDestroy(o)
                    }
                    sleep(Duration.Zero)
                }
                sleep(checkInterval)
            }
        }
    }
    private func startCreationSchedule() {
        spawn {
            while (running.load() && let _ <- tasks.remove()) {
                while(running.load() && size.load() < maxSize){
                    try{
                        let object = creator()
                        if (checkOnCreation && !checker(object)) {
                            destroy(object, true, decr: false)
                            sleep(Duration.Zero)
                            continue
                        } else if (add(object, decrIfOverload: false)) {
                            size.fetchAdd(1)
                        }
                    }catch(e: Exception){
                        log.warn('error on creation', e)
                        sleep(Duration.Zero)
                        continue
                    }
                    break
                }
                sleep(Duration.Zero)
            }
        }
    }
    private func destroy(o: T, logOnEx: Bool, decr!: Bool = true) {
        try {
            destroier(o)
        } catch (e: Exception) {
            if (logOnEx) {
                log.warn('error occurred on destring object in pool', e)
            } else {
                throw e
            }
        } finally {
            if (decr) {
                size.fetchSub(1)
            }
        }
        if (size.load() < 0) {
            let ex = PoolException(
                'current size of pool is less than zero, may be some instances which were not be created by current pool were destroied by current pool on giving back.')
            if (logOnEx) {
                log.warn(ex)
            } else {
                throw ex
            }
        }
    }
    private func add(object: T, decrIfOverload!: Bool = true): Bool {
        if (!queue.tryAdd((object, MonoTime.now()))) {
            log.warn {
                "current size of pool is larger than maxSize(${maxSize}), may be some instances which were not be created by current pool were given back to current pool."
            }
            destroy(object, false, decr: decrIfOverload)
            false
        } else {
            true
        }
    }
    public func isClosed(): Bool {
        !running.load()
    }
    public func close(): Unit {
        running.store(false)
        while (let Some(c) <- tasks.tryRemove()) {}
        while (let Some((o, _)) <- queue.tryRemove()) {
            destroy(o, true)
        }
    }
    public func borrow(timeout!: Duration = Duration.Max): ?T {
        func doCheck(o: T): ?T {
            if (checkOnBorrowing && !checker(o)) {
                destroy(o, true)
                return None<T>
            }
            o
        }
        let start = MonoTime.now()
        while (running.load() && MonoTime.now() - start < timeout) {
            if (let Some((o, _)) <- queue.tryRemove()) {
                if (let Some(x) <- doCheck(o)) {
                    return x
                }
            } else {
                tasks.tryAdd(())
                if (let consumed <- MonoTime.now() - start && consumed < timeout && let Some((o, _)) <- queue.remove(
                    timeout - consumed) && let Some(x) <- doCheck(o)) {
                    return x
                }
            }
        }
        None<T>
    }
    public func giveBack(object: T): Unit {
        func doAdd() {
            if (clearOnReturning) {
                clear(object)
            }
            add(object)
        }
        if (!running.load()) {
            destroy(object, true)
        } else if (checkOnReturning) {
            if (checker(object)) {
                doAdd()
            } else {
                destroy(object, true)
            }
        } else {
            doAdd()
        }
    }
}

public class PoolBuilder<T> {
    private var initSize: Int64 = 0
    private var minSize: Int64 = 0
    private var maxSize: Int64 = 10
    private var idleTimeout: Duration = Duration.hour
    private var checkOnCreation: Bool = false
    private var checkOnBorrowing: Bool = true
    private var checkOnReturning: Bool = true
    private var clearOnReturning: Bool = false
    private var checkInterval: Duration = Duration.minute
    private var creator: ?() -> T = None
    private var checker: ?(T) -> Bool = None
    private var destroier: ?(T) -> Unit = None
    private var clear: (T) -> Unit = {_ =>}

    init(){}
    public func setInitSize(initSize: Int64): This {
        this.initSize = initSize
        this
    }
    public func setMinSize(minSize: Int64): This {
        this.minSize = minSize
        this
    }
    public func setMaxSize(maxSize: Int64): This {
        this.maxSize = maxSize
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
    public func setCreator(creator: () -> T): This {
        this.creator = creator
        this
    }
    public func setChecker(checker: (T) -> Bool): This {
        this.checker = checker
        this
    }
    public func setDestroier(destroier: (T) -> Unit): This {
        this.destroier = destroier
        this
    }
    public func setClear(clear: (T) -> Unit): This {
        this.clear = clear
        this
    }
    public func setManager(manager: PooledManager<T>): This {
        setCreator(manager.create)
        setChecker(manager.check)
        setDestroier(manager.destroy)
        setClear(manager.clear)
        this
    }
    public func build(): Pool<T> {
        func toThrow(){
            throw PoolException('creator, checker and destroier must be set.')
        }
        Pool<T>(
            initSize: initSize,
            minSize: minSize,
            maxSize: maxSize,
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
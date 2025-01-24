/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_pool

import std.collection.concurrent.ArrayBlockingQueue
import std.process.Process
import std.sync.{AtomicInt64, AtomicBool, MultiConditionMonitor, ConditionID}
import std.time.MonoTime

import f_log.LoggerFactory

public interface PooledManager<T> where T <: Object {
    func create(): T
    func check(object: T): Bool
    func destroy(object: T): Unit
}
/**
 * 本类型无法分辨返还的实例是不是从Pool借出去的，也无法分辨借出实例的Pool跟返回实例的Pool是不是同一个，因此调用giveBack返还实例的时候，如果返回时检查失败了一定会销毁返还的实例，池维护的实例数随之减1。
 */
public class Pool<T> <: Resource where T <: Object {
    private static let log = LoggerFactory.getLogger<Pool<T>>()
    private let queue: ArrayBlockingQueue<(?T, MonoTime)>
    private let tasks: ArrayBlockingQueue<ConditionID>
    private let size = AtomicInt64(0)
    private let running = AtomicBool(false)
    private let monitor = MultiConditionMonitor()
    public Pool(
        private let initSize!: Int64 = 0,
        private let minSize!: Int64 = 0,
        private let maxSize!: Int64 = Int64.Max,
        private let elementLife!: Duration = Duration.hour,
        private let checkOnBorrowing!: Bool = true,
        private let checkOnReturning!: Bool = true,
        private let checkInterval!: Duration = Duration.minute,
        private let creator!: () -> T,
        private let checker!: (T) -> Bool,
        private let destroier!: (T) -> Unit
    ) {
        queue = ArrayBlockingQueue<(?T, MonoTime)>(maxSize)
        tasks = ArrayBlockingQueue<ConditionID>(maxSize)
        add(None<T>)
        startCheckingSchedule()
        startCreationSchedule()
        for (i in 0..initSize) {
            synchronized(monitor){
                tasks.enqueue(monitor.newCondition())
            }
        }
        running.store(true)
        Process.current.atExit(close)
    }
    public init(
        initSize!: Int64 = 0,
        minSize!: Int64 = 0,
        maxSize!: Int64 = Int64.Max,
        elementLife!: Duration = Duration.hour,
        checkOnBorrowing!: Bool = true,
        checkOnReturning!: Bool = true,
        checkInterval!: Duration = Duration.minute,
        manager!: PooledManager<T>
    ) {
        this(initSize: initSize, minSize: minSize, maxSize: maxSize, elementLife: elementLife,
            checkOnBorrowing: checkOnBorrowing, checkOnReturning: checkOnReturning, creator: manager.create,
            checker: manager.check, destroier: manager.destroy)
    }
    private func startCheckingSchedule() {
        spawn {
            while (running.load()) {
                while (running.load() && size.load() > minSize && let x <- queue.dequeue()) {
                    if(let (Some(o), t) <- x){
                        if (MonoTime.now() - t >= elementLife || !checker(o)) {
                            destroy(o, true)
                        } else {
                            queue.enqueue(x)
                        }
                    }else{
                        queue.enqueue(x)
                        break
                    }
                }
                sleep(checkInterval)
            }
        }
    }
    private func startCreationSchedule() {
        spawn {
            while (running.load() && let cond <- tasks.dequeue()) {
                if (!running.load()) {
                    return
                } else if (size.load() < maxSize) {
                    add(creator())
                    size.fetchAdd(1)
                    synchronized(monitor) {
                        monitor.notify(cond)
                    }
                }
            }
        }
    }
    private func destroy(o: T, logOnEx: Bool) {
        try{
            destroier(o)
        }catch(e: Exception){
            if(logOnEx){
                log.warn('error occurred on destring object in pool', e)
            }else{
                throw e
            }
        }finally{
            size.fetchSub(1)
        }
        if(size.load() < 0){
            let ex = PoolException('current size of pool is less than zero, may be some instances which were not be created by current pool were destroied by current pool on giving back.')
            if(logOnEx){
                log.warn(ex)
            }else{
                throw ex
            }
        }
    }
    private func add(object: ?T): Unit {
        if(!queue.tryEnqueue((object, MonoTime.now()))){
            throw PoolException("current size of pool is larger than maxSize(${maxSize}), may be some instances which were not be created by current pool were given back to current pool.")
        }
    }
    public func isClosed(): Bool {
        running.load()
    }
    public func close(): Unit {
        running.store(false)
        queue.tryEnqueue((None<T>, MonoTime.now()))
        while(let Some(c) <- tasks.tryDequeue()){}
        while (let Some(x) <- queue.tryDequeue() && let (Some(o), _) <- x) {
            destroy(o, true)
        }
    }
    public func borrow(timeout!: Duration = Duration.Max): ?T {
        let start = MonoTime.now()
        while (MonoTime.now() - start >= timeout && let Some((x, t)) <- queue.tryDequeue()) {
            if (let Some(o) <- x) {
                if (checkOnBorrowing) {
                    if (checker(o)) {
                        return o
                    } else {
                        destroy(o, true)
                    }
                } else {
                    return o
                }
            } else {
                queue.tryEnqueue((x, t))
            }
        }
        var consumed = MonoTime.now() - start
        while (size.load() < maxSize && timeout > consumed) {
            synchronized(monitor) {
                let cond = monitor.newCondition()
                tasks.tryEnqueue(cond)
                if(!monitor.wait(cond, timeout: timeout - consumed)){
                    return None<T>
                }
            }
            if (let Some((Some(o), t)) <- queue.tryDequeue()) {
                if (checkOnBorrowing) {
                    if (checker(o)) {
                        return o
                    } else {
                        destroy(o, true)
                    }
                } else {
                    return o
                }
            }
            consumed = MonoTime.now() - start
        }
        None<T>
    }
    public func giveBack(object: T): Unit {
        if (checkOnReturning) {
            if (checker(object)) {
                add(object)
            } else {
                destroy(object, false)
            }
        } else {
            add(object)
        }
    }
}

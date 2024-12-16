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

import std.collection.concurrent.BlockingQueue
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
 * 本类型无法分辨返回的实例是不是从Pool借出去的，也无法分辨借出实例的Pool跟返回实例的Pool是不是同一个，因此调用giveBack返还实例的时候，如果返回时检查失败了一定会销毁返还的实例，池维护的实例数随之减1。
 */
public class Pool<T> <: Resource where T <: Object {
    private static let log = LoggerFactory.getLogger<Pool<T>>()
    private let queue = BlockingQueue<(?T, MonoTime)>()
    private let tasks = BlockingQueue<ConditionID>()
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
        private let creator!: () -> T,
        private let checker!: (T) -> Bool,
        private let destroier!: (T) -> Unit
    ) {
        add(None)
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
                        if (MonoTime.now() - t >= elementLife) {
                            destroy(o, true)
                        } else {
                            queue.enqueue(x)
                        }
                    }else{
                        queue.enqueue(x)
                        break
                    }
                }
                sleep(Duration.second)
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
    }
    private func add(object: ?T): Unit {
        queue.enqueue((object, MonoTime.now()))
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
                monitor.wait(cond, timeout: timeout - consumed)
            }
            if (let Some(x) <- queue.tryDequeue() && let (Some(o), t) <- x) {
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

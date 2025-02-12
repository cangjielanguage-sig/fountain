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
import std.sync.{AtomicInt64, AtomicBool}
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
    private let queue: ArrayBlockingQueue<(T, MonoTime)>
    private let tasks: ArrayBlockingQueue<Unit>
    private let size = AtomicInt64(0)
    private let running = AtomicBool(true)
    public Pool(
        private let initSize!: Int64 = 0,
        private let minSize!: Int64 = 0,
        private let maxSize!: Int64 = Int64.Max,
        private let elementLife!: Duration = Duration.hour,
        private let checkOnCreation!: Bool = false,
        private let checkOnBorrowing!: Bool = true,
        private let checkOnReturning!: Bool = true,
        private let checkInterval!: Duration = Duration.minute,
        private let creator!: () -> T,
        private let checker!: (T) -> Bool,
        private let destroier!: (T) -> Unit
    ) {
        queue = ArrayBlockingQueue<(T, MonoTime)>(maxSize)
        tasks = ArrayBlockingQueue<Unit>(maxSize)
        startCheckingSchedule()
        startCreationSchedule()
        for (_ in 0..initSize) {
            tasks.enqueue(())
        }
        Process.current.atExit(close)
    }
    public init(
        initSize!: Int64 = 0,
        minSize!: Int64 = 0,
        maxSize!: Int64 = Int64.Max,
        elementLife!: Duration = Duration.hour,
        checkOnCreation!: Bool = false,
        checkOnBorrowing!: Bool = true,
        checkOnReturning!: Bool = true,
        checkInterval!: Duration = Duration.minute,
        manager!: PooledManager<T>
    ) {
        this(initSize: initSize, minSize: minSize, maxSize: maxSize, elementLife: elementLife,
            checkOnCreation: checkOnCreation, checkOnBorrowing: checkOnBorrowing, checkOnReturning: checkOnReturning, 
            checkInterval: checkInterval, creator: manager.create, checker: manager.check, destroier: manager.destroy)
    }
    private func startCheckingSchedule() {
        spawn {
            while (running.load()) {
                var i = 0
                while (running.load() && i < this.size.load() && let (o, t) <- queue.dequeue()) {
                    i++
                    try{
                        if (MonoTime.now() - t >= elementLife || !checker(o)) {
                            destroy(o, true)
                            if(this.size.load() < minSize){
                                tasks.tryEnqueue(())
                            }
                        } else {
                            queue.enqueue((o, t))
                        }
                    }catch(e: Exception){
                        log.warn('Pool checking schedule', e)
                    }
                }
                sleep(checkInterval)
            }
        }
    }
    private func startCreationSchedule() {
        spawn {
            while (running.load() && let _ <- tasks.dequeue()) {
                if (running.load() && size.load() < maxSize) {
                    let object = creator()
                    if(checkOnCreation && !checker(object)){
                        destroy(object, true)
                        continue
                    }
                    add(object)
                    size.fetchAdd(1)
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
    private func add(object: T): Unit {
        if(!queue.tryEnqueue((object, MonoTime.now()))){
            log.warn("current size of pool is larger than maxSize(${maxSize}), may be some instances which were not be created by current pool were given back to current pool.")
            destroy(object, false)
        }
    }
    public func isClosed(): Bool {
        running.load()
    }
    public func close(): Unit {
        running.store(false)
        while(let Some(c) <- tasks.tryDequeue()){}
        while (let Some((o, _)) <- queue.tryDequeue()) {
            destroy(o, true)
        }
    }
    public func borrow(timeout!: Duration = Duration.Max): ?T {
        let start = MonoTime.now()
        while (running.load() && MonoTime.now() - start >= timeout && let Some((o, t)) <- queue.tryDequeue()) {
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
        var consumed = MonoTime.now() - start
        while (running.load() && timeout > consumed) {
            tasks.tryEnqueue(())
            if (let Some((o, t)) <- queue.dequeue(timeout - consumed)) {
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
        if(!running.load()){
            destroy(object, true)
        }else if (checkOnReturning) {
            if (checker(object)) {
                add(object)
            } else {
                destroy(object, true)
            }
        } else {
            add(object)
        }
    }
}

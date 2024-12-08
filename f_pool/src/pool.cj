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
import std.sync.{AtomicInt64, AtomicBool}
import std.time.MonoTime

public interface PooledManager<T> where T <: Object {
    func create(): T
    func check(object: T): Bool
    func destroy(object: T): Unit
}

public class Pool<T> <: Resource where T <: Object {
    private let queue = BlockingQueue<(?T, MonoTime)>()
    private let tasks = BlockingQueue<Unit>()
    private let size = AtomicInt64(0)
    private let running = AtomicBool(false)
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
            tasks.enqueue(())
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
                var i = 0
                while (i < maxSize && size.load() > minSize && let x <- queue.dequeue()) {
                    if (!running.load()) {
                        return
                    } else if (let (Some(o), t) <- x && MonoTime.now() - t >= elementLife) {
                        destroy(o)
                    } else {
                        queue.enqueue(x)
                    }
                    i++
                }
                sleep(Duration.second)
            }
        }
    }
    private func startCreationSchedule() {
        spawn {
            while (running.load() && let _ <- tasks.dequeue()) {
                if (!running.load()) {
                    return
                } else if (size.load() < maxSize) {
                    add(creator())
                    size.fetchAdd(1)
                }
            }
        }
    }
    private func destroy(o: T){
        destroier(o)
        size.fetchSub(1)
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
        tasks.tryEnqueue(())
        while(let Some(x) <- queue.tryDequeue() && let (Some(o), _) <- x){
            destroy(o)
        }
    }
    public func borrow(timeout!: Duration = Duration.Max): ?T {
        let start = MonoTime.now()
        while (MonoTime.now() - start >= timeout && let Some((x, t)) <- queue.tryDequeue()) {
            if(let Some(o) <- x){
                if(checkOnBorrowing){
                    if(checker(o)){
                        return o
                    }else{
                        destroy(o)
                    }
                }else{
                    return o
                }
            }else{
                queue.tryEnqueue((x, t))
            }
        }
        let consumed = MonoTime.now() - start
        if(consumed >= timeout || size.load() >= maxSize){
            return None<T>
        }
        tasks.tryEnqueue(())
        if(let Some(x) <- queue.dequeue(timeout - consumed) && let (Some(o), t) <- x){
            if(checkOnBorrowing){
                if(checker(o)){
                    return o
                }else{
                    destroy(o)
                }
            }else{
                return o
            }
        }
        None<T>
    }
    public func giveBack(object: T): Unit {
        if(checkOnReturning){
            if(checker(object)){
                add(object)
            }else{
                destroy(object)
                tasks.tryEnqueue(())
            }
        }else{
            add(object)
        }
    }
}

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
package fountain::f_concurrent

import std.collection.concurrent.ArrayBlockingQueue
import std.sync.{AtomicBool, Mutex, Condition}
import std.time.MonoTime

public struct Executors<T> {
    private let executors: Array<Executor<T>>
    public init(executors!: Int64 = 1024, maxQueueSize!: Int64 = 1){
        let q = ArrayBlockingQueue<()->Unit>(executors)
        this.executors = Array<Executor<T>>(executors){_ => Executor<T>(q)}
    }
    public func call(task: () -> ?T): ExecutorFuture<T> {
        executors[0].call(task)
    }
    public func call(timeout: Duration, task: () -> ?T): ExecutorFuture<T>{
        executors[0].call(timeout, task)
    }
    public func tryCall(task: () -> ?T): ExecutorFuture<T> {
        executors[0].tryCall(task)
    }
    public func call(limiter: RateLimiter<Unit>, task: () -> ?T): ExecutorFuture<T> {
        executors[0].call(limiter, task)
    }
    public func call(limiter: RateLimiter<Unit>, default: ?T, task: () -> ?T): ExecutorFuture<T> {
        executors[0].call(limiter, default, task)
    }
    public func shutdown(): Unit {
        for(e in executors){
            e.shutdown()
        }
    }
}
public class Executor<T> {
    private let running = AtomicBool(true)
    private let mutex = Mutex()
    private let condition = synchronized(mutex){
        mutex.condition()
    }
    private var result = ConcurrentHashMap<Int64, T>()
    Executor(private let q: ArrayBlockingQueue<()->Unit>){
        spawn {
            while(running.load()){
                q.remove()()
            }
        }
    }
    public init(maxQueueSize!: Int64 = 1024){
        this(ArrayBlockingQueue<()->Unit>(maxQueueSize))
    }
    public func call(task: () -> ?T): ExecutorFuture<T> {
        let future = ExecutorFuture<T>(mutex, condition)
        q.add({=> 
            synchronized(mutex){
                future.result = task()
                condition.notifyAll()
            }
        })
        future
    }
    public func call(timeout: Duration, task: () -> ?T): ExecutorFuture<T> {
        let future = ExecutorFuture<T>(mutex, condition)
        let added = q.add({=> 
            synchronized(mutex){
                future.result = task()
                future.finished = true
                condition.notifyAll()
            }
        }, timeout)
        if(!added){
            future.finished = true
        }
        future
    }
    public func tryCall(task: () -> ?T): ExecutorFuture<T> {
        call(Duration.Zero, task)
    }
    public func call(limiter: RateLimiter<Unit>, task: () -> ?T): ExecutorFuture<T> {
        call(limiter, None, task)
    }
    public func call(limiter: RateLimiter<Unit>, default: ?T, task: () -> ?T): ExecutorFuture<T> {
        let future = ExecutorFuture<T>(mutex, condition)
        limiter.exec{
            let added = q.tryAdd({=> 
                synchronized(mutex){
                    future.result = task()
                    future.finished = true
                    condition.notifyAll()
                }
            })
            if(!added){
                future.result = default
                future.finished = true
            }
        }
        future
    }
    public func shutdown(){
        running.store(false)
    }
}
public class ExecutorFuture<T> {
    var result = None<T>
    var finished = false
    ExecutorFuture(private let mutex: Mutex, private let condition: Condition){}
    public func get(): T {
        get(None<T>).getOrThrow()
    }
    public func get(default: ?T): ?T {
        synchronized(mutex){
            while(!finished){
                if(let Some(r) <- result){
                    return r
                }
                condition.wait()
            }
        }
        default
    }
    public func tryGet(): ?T {
        result
    }
    public func get(timeout: Duration): ?T {
        synchronized(mutex){
            var waited = Duration.Zero
            let start = MonoTime.now()
            while(!finished && waited < timeout){
                if(let Some(r) <- result){
                    return r
                }
                waited = MonoTime.now() - start
                if(!condition.wait(timeout: timeout - waited)){
                    return None
                }
            }
        }
        result
    }
}
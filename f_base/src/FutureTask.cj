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
package fountain::f_base

import std.collection.concurrent.ConcurrentHashMap
import std.collection.HashSet
import std.sync.{Mutex, AtomicInt64}

private class FutureTaskException <: BaseException {
    public init() {}

    public init(message: String) {
        super(message)
    }
    public init(caused: Exception) {
        super(caused)
    }
    public init(message: String, caused: Exception) {
        super(message, caused)
    }
}
public sealed abstract class AbstractFutureTask <: Hashable & Equatable<AbstractFutureTask>{
    private let local = ConcurrentHashMap<AbstractInheritedTaskLocal, Any>()
    static let taskMap = ConcurrentHashMap<Int64, AbstractFutureTask>()
    protected let tid = AtomicInt64(0)
    let parentTID = Thread.currentThread.id
    public func hashCode(): Int64 {
        tid.load()
    }
    public operator func ==(other: AbstractFutureTask): Bool {
        tid.load() == other.tid.load()
    }
    public func newLocal<T>(): InheritedTaskLocal<T> {
        InheritedTaskLocal(this)
    }
    func setLocal<T>(local: AbstractInheritedTaskLocal, value: T): Unit {
        this.local.add(local, value)
    }
    func getLocal<T>(local: AbstractInheritedTaskLocal): ?T {
        var tid = Thread.currentThread.id
        while(let Some(current: AbstractFutureTask) <- taskMap.get(tid)){
            if(let Some(x: T) <- current.local.get(local)){
                return x
            }
            tid = current.parentTID
        }
        None<T>
    }
    func removeLocal<T>(local: AbstractInheritedTaskLocal): ?T {
        if(let Some(x: T) <- this.local.remove(local)){
            x
        }else{
            None<T>
        }
    }
    func getOrSetLocal<T>(local: AbstractInheritedTaskLocal, value: T): T {
        if(let Some(x: T) <- getLocal<T>(local)){
            x
        }else{
            setLocal<T>(local, value)
            value
        }
    }
    func getOrComputeLocal<T>(local: AbstractInheritedTaskLocal, fn: () -> T): T {
        if(let Some(x: T) <- getLocal<T>(local)){
            x
        }else{
            let value = fn()
            setLocal<T>(local, value)
            value
        }
    }
}

public class FutureTask<T> <: AbstractFutureTask {
    private static let subTasks = ConcurrentHashMap<Int64, HashSet<AbstractFutureTask>>()
    private let mutex = Mutex()
    private var future = None<Future<T>>
    
    public init(shutdownSubOnFinish: Bool, fn: () -> T){
        let task = this
        this.future = spawn{
            let tid = Thread.currentThread.id
            task.tid.store(tid)
            taskMap.add(tid, task)
            synchronized(mutex){
                if(let Some(set) <- subTasks.get(parentTID)){
                    set
                }else{
                    let set = HashSet<AbstractFutureTask>()
                    subTasks.add(parentTID, set)
                    set
                }.add(task)
            }
            try{
                fn()
            }finally{
                taskMap.remove(tid)
                synchronized(mutex){
                    if(let Some(set) <- subTasks.get(parentTID)){
                        set.remove(task)
                        if(set.isEmpty()){
                            subTasks.remove(parentTID)
                        }
                    }
                }
                if(shutdownSubOnFinish){
                    shutdownCurrentSubThreads()
                }
            }
        }
    }
    public init(fn: () -> T){
        this(true, fn)
    }
    public static func current(): FutureTask<T> {
        if(let Some(t: FutureTask<T>) <- taskMap.get(Thread.currentThread.id)){
            t
        }else{
            throw FutureTaskException("No task found in current thread")
        }
    }
    public func get(): T {
        future.getOrThrow().get()
    }
    public func get(timeout: Duration): T{
        future.getOrThrow().get(timeout)
    }
    public func tryGet(): ?T {
        future.getOrThrow().tryGet()
    }

    public func shutdown(): Unit {
        future?.cancel()
        shutdownCurrentSubThreads()
    }
    public static func shutdownCurrentSubThreads(): Unit {
        if(let Some(set) <- subTasks.remove(Thread.currentThread.id)){
            let itr = set .iterator()
            while(let Some(f: FutureTask<T>) <- itr.next()){
                f.shutdown()
            }
        }
    }
}
public sealed abstract class AbstractInheritedTaskLocal <: Hashable & Equatable<AbstractInheritedTaskLocal> {
    AbstractInheritedTaskLocal(let task: AbstractFutureTask){}
    public func hashCode(): Int64 {
        task.hashCode()
    }
    public operator func ==(other: AbstractInheritedTaskLocal): Bool {
        refEq(this, other)
    }
}
public class InheritedTaskLocal<T> <: AbstractInheritedTaskLocal {
    init(task: AbstractFutureTask){
        super(task)
    }

    public func set(value: T): Unit {
        task.setLocal<T>(this, value)
    }

    public func get(): ?T {
        task.getLocal<T>(this)
    }

    public func remove(): Unit {
        task.removeLocal<T>(this)
    }
    public func getOrSet(value: T): T {
        task.getOrSetLocal<T>(this, value)
    }
    public func getOrCompute(fn: () -> T): T {
        task.getOrComputeLocal<T>(this, fn)
    }
}
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
    // FT-1（bug-f_base.md §1.1）：任务身份必须是构造期分配、终生不变的 id。
    // 不能用 tid（线程 id）：构造期它恒为 0、任务线程启动后才写入真实值，
    // 这会让 InheritedTaskLocal 的键（哈希取自 hashCode）在写入与读取时进不同的桶 ⇒ 值丢失。
    private static let nextTaskId = AtomicInt64(0)
    private let taskId = nextTaskId.fetchAdd(1)
    private let local = ConcurrentHashMap<AbstractInheritedTaskLocal, Any>()
    static let taskMap = ConcurrentHashMap<Int64, AbstractFutureTask>()
    // FT-2（bug-f_base.md §1.2）：子任务登记表的**全部**访问（登记/注销/整体取走）共用这一把锁。
    // 原来保护它的是每个 FutureTask 实例自己的 mutex ⇒ 同一父任务的多个子任务之间毫无互斥，
    // 而 HashSet 不是线程安全的，父任务还会在迭代时被子任务并发 add/remove。
    static let subTasksLock = Mutex()
    static let subTasks = ConcurrentHashMap<Int64, HashSet<AbstractFutureTask>>()
    protected let tid = AtomicInt64(0)
    let parentTID = Thread.currentThread.id
    public func hashCode(): Int64 {
        taskId
    }
    public operator func ==(other: AbstractFutureTask): Bool {
        taskId == other.taskId
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
    // FT-4 二次决策：二段检查锁 —— 第一段无锁快路径；未命中才进锁，锁内复查后只有一个调用方写入
    func getOrSetLocal<T>(local: AbstractInheritedTaskLocal, value: T): T {
        if(let Some(x: T) <- getLocal<T>(local)){
            x
        }else{
            synchronized(local.initLock){
                if(let Some(x: T) <- getLocal<T>(local)){
                    x
                }else{
                    setLocal<T>(local, value)
                    value
                }
            }
        }
    }
    func getOrComputeLocal<T>(local: AbstractInheritedTaskLocal, fn: () -> T): T {
        if(let Some(x: T) <- getLocal<T>(local)){
            x
        }else{
            synchronized(local.initLock){
                if(let Some(x: T) <- getLocal<T>(local)){
                    x
                }else{
                    let value = fn()
                    setLocal<T>(local, value)
                    value
                }
            }
        }
    }
    // FT-3（bug-f_base.md §2.1）：取消/关闭能力落在 AbstractFutureTask 上，子任务表的迭代才不必
    // 按 `FutureTask<T>` 匹配（T 取调用方的泛型实参）——否则与调用方实参不同的子任务会被静默跳过：
    // 父任务 FutureTask<Unit> 关不掉它自己的 FutureTask<Int64> 子任务。
    public func shutdown(): Unit {
        cancelSelf()
        shutdownCurrentSubThreads()
    }
    // 子类在这里挂各自的取消手段（FutureTask<T> 走 future.cancel()）
    protected open func cancelSelf(): Unit {}
    public static func shutdownCurrentSubThreads(): Unit {
        // FT-2：先在锁内把整张子任务表**取走**，再在锁外逐个发取消信号：
        // 迭代因此不会与并发的 add/remove 打架，用户可见的取消动作也不在锁里做。
        let mine = synchronized(subTasksLock){
            subTasks.remove(Thread.currentThread.id)
        }
        match (mine) {
            case Some(set) =>
                let itr = set.iterator()
                while(let Some(f: AbstractFutureTask) <- itr.next()){
                    f.shutdown()
                }
            case None => ()
        }
    }
}

public class FutureTask<T> <: AbstractFutureTask {
    private var future = None<Future<T>>

    public init(shutdownSubOnFinish: Bool, fn: () -> T){
        let task = this
        // FT-2：登记由**创建线程**（父任务）在起线程之前同步完成，并与注销/整体取走共用 subTasksLock。
        // 登记先于 spawn ⇒ 子任务开始运行时必然已在表里，父任务的 shutdown 不会漏掉它；
        // 反过来，能对该任务调 shutdown 的只有它的创建线程（此刻正忙于本构造函数），
        // 因此"登记已完成、future 尚未赋值"这段窗口不会造成漏取消，却让临界区不再包住 spawn
        // （临界区包住 spawn 会让子任务拆除时抢锁、把构造路径的延迟推高 ~4µs/任务）。
        synchronized(subTasksLock){
            if(let Some(set) <- subTasks.get(parentTID)){
                set.add(task)
            }else{
                let set = HashSet<AbstractFutureTask>()
                set.add(task)
                subTasks.add(parentTID, set)
            }
        }
        this.future = spawn{
            let tid = Thread.currentThread.id
            task.tid.store(tid)
            taskMap.add(tid, task)
            try{
                fn()
            }finally{
                taskMap.remove(tid)
                synchronized(subTasksLock){
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

    // FT-3：shutdown()/shutdownCurrentSubThreads() 由 AbstractFutureTask 提供（对 `FutureTask<T>.xxx` 的调用照旧可用）
    protected override func cancelSelf(): Unit {
        future?.cancel()
    }
}
public sealed abstract class AbstractInheritedTaskLocal <: Hashable & Equatable<AbstractInheritedTaskLocal> {
    // FT-4 二次决策（bug-f_base.md §2.2）：getOrSet/getOrCompute 用的二段检查锁。
    // 粒度 = 每个 local —— 一个 local 只对应"某个任务表里的一个槽"，正好覆盖该槽的全部写入者；
    // fn() 在锁内执行（保证只算一次），Cangjie 的 Mutex 可重入 ⇒ fn 内再对同一 local 调
    // getOrCompute 不会死锁（那次会再算一次并覆盖，属已文档化的例外）。
    let initLock = Mutex()
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

    // FT-4（bug-f_base.md §2.2，路线 2）：写/删的目标 = 当前线程所属的任务（"当前任务"）；
    // 调用方不在任务里（创建线程、main 线程等）时回退到 owner —— 即创建这个 local 的任务。
    private func writeTarget(): AbstractFutureTask {
        match (AbstractFutureTask.taskMap.get(Thread.currentThread.id)) {
            case Some(running) => running
            case None => task
        }
    }

    public func set(value: T): Unit {
        writeTarget().setLocal<T>(this, value)
    }

    public func get(): ?T {
        task.getLocal<T>(this)
    }

    public func remove(): Unit {
        writeTarget().removeLocal<T>(this)
    }
    // 决策：getOrSet/getOrCompute 保持现状 —— 未命中时写 owner 的共享槽（该任务与整个子树可见），不加锁
    public func getOrSet(value: T): T {
        task.getOrSetLocal<T>(this, value)
    }
    public func getOrCompute(fn: () -> T): T {
        task.getOrComputeLocal<T>(this, fn)
    }
}
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
import std.collection.{HashMap, HashSet}
import std.sync.{Mutex, AtomicInt64}

public class FutureTaskException <: BaseException {
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
    // FT-6 ⑥+①（bug-f_base.md §2.4 量化）：local 由「每任务一张 ConcurrentHashMap」改为
    // 「Mutex + HashMap，且首次写入才建表」。
    // 依据（EXP18，同进程实测）：空 ConcurrentHashMap 的构造就要 3.6~5.2µs/次
    // （同尺寸 HashMap 0.42~0.55µs、纯数组 0.27µs），单次操作 ≈0.6µs（Mutex+HashMap ≈0.19µs 读 / 0.34µs 写）；
    // 本结构读多写少、并发度低（写入方只有当前任务或 owner 的子树），Mutex 足够。
    // 并发口径：local 的**全部**访问（读也在内）都在 localLock 内完成 —— 于是"首次写入才建表"
    // 不需要额外的原子发布协议，也没有跨线程可见性问题；锁不跨越用户代码，
    // 锁序固定为 local.initLock → task.localLock（无反向；Mutex 本身可重入）。
    private let localLock = Mutex()
    private var local: ?HashMap<AbstractInheritedTaskLocal, Any> = None
    static let taskMap = ConcurrentHashMap<Int64, AbstractFutureTask>()
    // FT-2（bug-f_base.md §1.2）：子任务登记表的**全部**访问（登记/注销/整体取走）共用这一把锁。
    // 原来保护它的是每个 FutureTask 实例自己的 mutex ⇒ 同一父任务的多个子任务之间毫无互斥，
    // 而 HashSet 不是线程安全的，父任务还会在迭代时被子任务并发 add/remove。
    static let subTasksLock = Mutex()
    static let subTasks = ConcurrentHashMap<Int64, HashSet<AbstractFutureTask>>()
    protected let tid = AtomicInt64(0)
    let parentTID = Thread.currentThread.id
    // FT-5（bug-f_base.md §2.3）：父任务是**构造期固定的树事实**，不随父任务结束而消失。
    // getLocal 的链式查找改走这条父链，于是"父任务先结束"不再切断继承；
    // 创建线程不是任务时（main 线程、普通 spawn 线程）为 None。
    let parent: ?AbstractFutureTask = taskMap.get(Thread.currentThread.id)
    public func hashCode(): Int64 {
        taskId
    }
    public operator func ==(other: AbstractFutureTask): Bool {
        taskId == other.taskId
    }
    public func newLocal<T>(): InheritedTaskLocal<T> {
        InheritedTaskLocal(this)
    }
    // FT-6 ⑥+①：读/写/删各自在 localLock 内完成；写路径首次调用时建表（懒分配）。
    private func readLocalRaw(local: AbstractInheritedTaskLocal): ?Any {
        synchronized(this.localLock){
            match(this.local){
                case Some(map) => map.get(local)
                case None => None<Any>
            }
        }
    }
    private func writeLocalRaw(local: AbstractInheritedTaskLocal, value: Any): Unit {
        synchronized(this.localLock){
            match(this.local){
                case Some(map) => map.add(local, value)
                case None =>
                    let map = HashMap<AbstractInheritedTaskLocal, Any>()
                    map.add(local, value)
                    this.local = map
            }
        }
    }
    private func removeLocalRaw(local: AbstractInheritedTaskLocal): ?Any {
        synchronized(this.localLock){
            match(this.local){
                case Some(map) => map.remove(local)
                case None => None<Any>
            }
        }
    }
    func setLocal<T>(local: AbstractInheritedTaskLocal, value: T): Unit {
        writeLocalRaw(local, value)
    }
    func getLocal<T>(local: AbstractInheritedTaskLocal): ?T {
        // FT-5：从「当前线程正在执行的任务」出发，沿构造期固定的父链上溯 ——
        // 不再依赖父任务是否还在 taskMap 里，因此父任务先结束也能继承到它的值。
        var current = taskMap.get(Thread.currentThread.id)
        while(let Some(task) <- current){
            if(let Some(x: T) <- task.readLocalRaw(local)){
                return x
            }
            current = task.parent
        }
        None<T>
    }
    func removeLocal<T>(local: AbstractInheritedTaskLocal): ?T {
        if(let Some(x: T) <- removeLocalRaw(local)){
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
    // FT-3 遗留收口：类型无关地取「当前线程正在执行的任务」。
    // FutureTask<T>.current() 只在该任务的泛型实参恰好是 T 时可用；下面两个入口不受实参限制。
    public static func current(): AbstractFutureTask {
        if(let Some(running) <- currentOrNone()){
            running
        }else{
            throw FutureTaskException("No task found in current thread")
        }
    }
    // 不在任务里（main 线程、普通 spawn 线程等）返回 None —— 便于分支处理，不必用 try/catch 当控制流
    public static func currentOrNone(): ?AbstractFutureTask {
        taskMap.get(Thread.currentThread.id)
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
    // 返回当前线程正在执行的 FutureTask<T>：要求该任务的泛型实参恰好为 T。
    // AbstractFutureTask 只有本类一个子类，所以"取不到"只有两种情况——不在任务里、或实参不一致，
    // 合并成一条消息即可；要类型无关的句柄用 AbstractFutureTask.current() / currentOrNone()。
    public static func current(): FutureTask<T> {
        if(let Some(t: FutureTask<T>) <- AbstractFutureTask.currentOrNone()){
            t
        }else{
            throw FutureTaskException("No FutureTask with the requested type argument found in current thread (a task of another type argument may be running); use AbstractFutureTask.current() instead")
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
        if(let Some(running) <- AbstractFutureTask.currentOrNone()){
            running
        }else{
            task
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
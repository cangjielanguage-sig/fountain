/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_rx

/**
 * 观察者调度器
 */
public abstract class Scheduler<T> {
    public Scheduler(protected var observer: Observer<T>) {}
    /**
     * 伪代码
     * try {
     *   match (item) {
     *     case Some(x) => observer.onNext(x)
     *     case _ => observer.onComplete()
     *   }
     * } catch(e: Exception) {
     *    observer.onError(e)
     * }
     */
    public func schedule(item: ?T): Unit
    /**
     * observer.onError(ex)
     */
    public func schedule(ex: Exception): Unit
    /**
     * 一直使用新线程执行观察者，observer是待执行的观察者
     */
    public static func alwaysNew(observer: Observer<T>): Scheduler<T> {
        AlwaysNewScheduler(observer)
    }
    /**
     * 使用当前线程执行观察者，observer是待执行的观察者
     */
    public static func current(observer: Observer<T>): Scheduler<T> {
        CurrentScheduler(observer)
    }
    /**
     * 开启一个新线程执行观察者，observer是待执行的观察者，被观察者产生的数据推入数据队列，这个线程不停地从队列取出数据。
     * queueSize是线程队列容量，policy是背压策略
     */
    public static func single(observer: Observer<T>, queueSize: Int64, policy!: BackPressure = BackPressure.Current): Scheduler<T> {
        SingleScheduler(observer, queueSize, policy: policy)
    }
    /**
     * 开启一个新线程执行观察者，observer是待执行的观察者
     * policy是背压策略
     */
    public static func single(observer: Observer<T>, policy!: BackPressure = BackPressure.Current): Scheduler<T> {
        SingleScheduler(observer, policy: policy)
    }
    /**
     * 开启threads个新线程执行观察者，observer是待执行的观察者，
     * 一个线程对应一个数据队列，被观察者的产生的数据按循环推入数据队列
     * queueSize是线程队列容量，policy是背压策略
     */
    public static func fixed(observer: Observer<T>, threads: Int64, policy!: BackPressure = BackPressure.Current): Scheduler<T> {
        FixedScheduler(observer, threads, policy: policy)
    }
    /**
     * 开启threads个新线程执行观察者，observer是待执行的观察者，
     * 一个线程对应一个数据队列，被观察者的产生的数据按循环推入数据队列
     * queueSize是线程队列容量，policy是背压策略
     */
    public static func fixed(observer: Observer<T>, threads: Int64, queueSize: Int64,
        policy!: BackPressure = BackPressure.Current): Scheduler<T> {
        FixedScheduler(observer, threads, queueSize, policy: policy)
    }
}

class AlwaysNewScheduler<T> <: Scheduler<T> {
    init(observer: Observer<T>) {
        super(observer)
    }
    public func schedule(item: ?T): Unit {
        spawn {
            try {
                if (let Some(v) <- item) {
                    this.observer.onNext(v)
                } else {
                    this.observer.onComplete()
                }
            } catch (e: Exception) {
                this.observer.onError(e)
            }
        }
    }
    public func schedule(ex: Exception): Unit {
        spawn {
            this.observer.onError(ex)
        }
    }
}

class CurrentScheduler<T> <: Scheduler<T> {
    init(observer: Observer<T>) {
        super(observer)
    }
    public func schedule(item: ?T): Unit {
        try {
            if (let Some(v) <- item) {
                this.observer.onNext(v)
            } else {
                this.observer.onComplete()
            }
        } catch (e: Exception) {
            this.observer.onError(e)
        }
    }
    public func schedule(ex: Exception): Unit {
        this.observer.onError(ex)
    }
}

enum SingleSchedulerState<T> {
    | Item(?T)
    | Ex(Exception)
    | Poison(SyncCounter, SingleScheduler<T>, Int64)
}

class SingleScheduler<T> <: Scheduler<T> {
    var wrapper = None<FixedScheduler<T>>
    private SingleScheduler(observer: Observer<T>, private let queue: LinkedBlockingQueue<SingleSchedulerState<T>>,
        private let policy!: BackPressure = BackPressure.Current, private let index!: Int64 = 0) {
        super(observer)
        spawn {
            try {
                while (let state <- queue.remove()) {
                    func exec(state: SingleSchedulerState<T>, steal: Bool): Bool {
                        match (state) {
                            case Item(item) => match (item) {
                                case Some(v) => this.observer.onNext(v)
                                case _ =>
                                    if (let Some(w) <- wrapper) {
                                        let queues = w.queues
                                        let qsize = queues.size
                                        let counter = SyncCounter(qsize)
                                        for (ss in queues) {
                                            ss.queue.add(Poison(counter, ss, index))//这里不能使用ss.schedule代替ss.queue.add，毒丸必须发送成功
                                        }
                                    }
                            }
                            case Ex(e) => this.observer.onError(e)
                            case Poison(c, ss, idx) where steal => ss.queue.add(Poison(c, ss, idx))
                            case Poison(c, _, idx) =>
                                c.dec()
                                if(idx == this.index){
                                    c.waitUntilZero()
                                    this.observer.onComplete()
                                }
                                return false
                        }
                        true
                    }
                    if (!exec(state, false)) {
                        return
                    }
                    var next = true
                    while (next && this.queue.size == 0 && let Some(w) <- wrapper) {
                        let queues = w.queues
                        let qsize = queues.size
                        var stolen = 0
                        for (i in 1..qsize) {
                            if (let Some(state) <- queues[(index + i) % qsize].queue.tryRemove()) {
                                stolen++
                                if (!exec(state, true)) {
                                    next = false
                                    break
                                }
                            }
                            if (next && this.queue.size > 0) {
                                break
                            }
                        }
                        if (stolen == 0) {
                            break
                        }
                        stolen = 0
                    }
                }
            } catch (e: Exception) {
                this.observer.onError(e)
            }
        }
    }

    init(observer: Observer<T>, size: Int64, policy!: BackPressure = BackPressure.Current, index!: Int64 = 0) {
        this(observer, LinkedBlockingQueue<SingleSchedulerState<T>>(size), policy: policy, index: index)
    }
    init(observer: Observer<T>, policy!: BackPressure = BackPressure.Current, index!: Int64 = 0) {
        this(observer, LinkedBlockingQueue<SingleSchedulerState<T>>(), policy: policy, index: index)
    }
    private func schedule(state: SingleSchedulerState<T>): Unit {
        if (queue.size < queue.capacity) {
            queue.add(state)
        } else {
            func callee(): Unit {
                try {
                    match (state) {
                        case Item(item) => match (item) {
                            case Some(v) => this.observer.onNext(v)
                            case _ => this.observer.onComplete()
                        }
                        case Ex(ex) => this.observer.onError(ex)
                        case Poison(c, _, idx) => 
                            c.dec()
                            if(idx == this.index){
                                c.waitUntilZero()
                                this.observer.onComplete()
                            }
                    }
                } catch (e: Exception) {
                    this.observer.onError(e)
                }
            }
            match (policy) {
                case Discarding => ()
                case DropOldest =>
                    queue.remove()
                    schedule(state)
                case BlockingOrDiscarding(d) => queue.add(state, d)
                case BlockingOrThrowing(d) =>
                    if (!queue.add(state, d)) {
                        throw FullSchedulerException()
                    }
                case Throwing => throw FullSchedulerException()
                case Current => callee()
                case NewThread => spawn {callee()}
                case Action(f) => f(callee)
            }
        }
    }
    public func schedule(item: ?T): Unit {
        schedule(Item(item))
    }
    public func schedule(ex: Exception): Unit {
        schedule(Ex(ex))
    }
}

class FixedScheduler<T> <: Scheduler<T> {
    private let index = AtomicInt64(0)
    private FixedScheduler(let queues: Array<SingleScheduler<T>>) {
        super(queues[0].observer)
        for (scheduler in queues) {
            scheduler.wrapper = this
        }
    }

    public init(observer: Observer<T>, threads: Int64, policy!: BackPressure = BackPressure.Current) {
        this(Array<SingleScheduler<T>>(threads) {i => SingleScheduler<T>(observer, policy: policy, index: i)})
    }
    public init(observer: Observer<T>, threads: Int64, queueSize: Int64, policy!: BackPressure = BackPressure.Current) {
        this(Array<SingleScheduler<T>>(threads) {i => SingleScheduler(observer, queueSize, policy: policy, index: i)})
    }
    private prop nextIndex: Int64 {
        get() {
            var idx = index.fetchAdd(1) % queues.size
            if (idx < 0) {
                idx = -idx
            }
            idx
        }
    }
    public func schedule(item: ?T): Unit {
        queues[nextIndex].schedule(item)
    }
    public func schedule(ex: Exception): Unit {
        queues[nextIndex].schedule(ex)
    }
}

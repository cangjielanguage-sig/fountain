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

public abstract class Scheduler<T> {
    public Scheduler(protected var observer: Observer<T>){}
    public func schedule(item: ?T): Unit
    public func schedule(ex: Exception): Unit
    public static func alwaysNew(observer: Observer<T>): Scheduler<T> {
        AlwaysNewScheduler(observer)
    }
    public static func current(observer: Observer<T>): Scheduler<T> {
        CurrentScheduler(observer)
    }
    public static func single(observer: Observer<T>, queueSize: Int64, policy!: BackPressure = BackPressure.Current): Scheduler<T> {
        SingleScheduler(observer, queueSize, policy: policy)
    }
    public static func single(observer: Observer<T>, policy!: BackPressure = BackPressure.Current): Scheduler<T> {
        SingleScheduler(observer, policy: policy)
    }
    public static func fixed(observer: Observer<T>, threads: Int64, policy!: BackPressure = BackPressure.Current): Scheduler<T> {
        FixedScheduler(observer, threads, policy: policy)
    }
    public static func fixed(observer: Observer<T>, threads: Int64, queueSize: Int64, policy!: BackPressure = BackPressure.Current): Scheduler<T> {
        FixedScheduler(observer, threads, queueSize, policy: policy)
    }
}
class AlwaysNewScheduler<T> <: Scheduler<T> {
    init(observer: Observer<T>){
        super(observer)
    }
    public func schedule(item: ?T): Unit {
        spawn {
            try{
                if(let Some(v) <- item) {
                    this.observer.onNext(v)
                }else{
                    this.observer.onComplete()
                }
            } catch(e: Exception) {
                this.observer.onError(e)
            }
        }
    }
    public func schedule(ex: Exception): Unit {
        spawn{
            this.observer.onError(ex)
        }
    }
}
class CurrentScheduler<T> <: Scheduler<T> {
    init(observer: Observer<T>){
        super(observer)
    }
    public func schedule(item: ?T): Unit {
        try{
            if(let Some(v) <- item) {
                this.observer.onNext(v)
            }
            this.observer.onComplete()
        } catch(e: Exception) {
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
}
class SingleScheduler<T> <: Scheduler<T> {
    private let mutex = Mutex()
    private SingleScheduler(
        observer: Observer<T>, 
        private let queue: LinkedBlockingQueue<SingleSchedulerState<T>>,
        private let policy!: BackPressure = BackPressure.Current) {
        super(observer)
        spawn{
            try{
                while(let state <- queue.remove()){
                    match(state){
                        case Item(item) => match(item){
                            case Some(v) => this.observer.onNext(v)
                            case _ => break
                        }
                        case Ex(e) => throw e
                    }
                }
                this.observer.onComplete()
            }catch(e: Exception) {
                this.observer.onError(e)
            }
        }
    }

    init(observer: Observer<T>, size: Int64, policy!: BackPressure = BackPressure.Current) {
        this(observer, LinkedBlockingQueue<SingleSchedulerState<T>>(size), policy: policy)
    }
    init(observer: Observer<T>, policy!: BackPressure = BackPressure.Current){
        this(observer, LinkedBlockingQueue<SingleSchedulerState<T>>(), policy: policy)
    }
    private func schedule(state: SingleSchedulerState<T>): Unit {
        if(queue.size < queue.capacity){
            queue.add(state)
        }else{
            func callee(): Unit {
                try{
                    match(state){
                        case Item(item) => match(item) {
                            case Some(v) => this.observer.onNext(v)
                            case _ => this.observer.onComplete()
                        }
                        case Ex(ex) => this.observer.onError(ex)
                    }
                }catch(e: Exception){
                    this.observer.onError(e)
                }
            }
            match(policy) {
                case Discarding => ()
                case DropOldest => 
                    queue.remove()
                    schedule(state)
                case BlockingOrDiscarding(d) => queue.add(state, d)
                case BlockingOrThrowing(d) => if(!queue.add(state, d)){
                    throw FullSchedulerException()
                }
                case Throwing => throw FullSchedulerException()
                case Current => callee()
                case NewThread => spawn{callee()}
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
    private FixedScheduler(private let queues: Array<SingleScheduler<T>>){
        super(queues[0].observer)
    }

    public init(observer: Observer<T>, threads: Int64, policy!: BackPressure = BackPressure.Current) {
        this(Array<SingleScheduler<T>>(threads, repeat:SingleScheduler<T>(observer, policy: policy)))
    }
    public init(observer: Observer<T>, threads: Int64, queueSize: Int64, policy!: BackPressure = BackPressure.Current){
        this(Array<SingleScheduler<T>>(threads, repeat: SingleScheduler(observer, queueSize, policy: policy)))
    }
    private prop nextIndex: Int64 {
        get(){
            var idx = index.fetchAdd(1) % queues.size
            if(idx < 0){
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
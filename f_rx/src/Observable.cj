/*
    Copyright (c) 2022 WuJingrun（吴京润）
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_rx

public class Observable<T> {
    private let observer: CombinedObserver<T>
    private var scheduler: Scheduler<T>
    private let disposed_ = AtomicBool(false)
    private let completionOnDisposing = AtomicBool(false)
    private Observable(private let items: () -> Iterator<T>, private let asyncCombined!: Bool = false) {
        this.observer = CombinedObserver<T>(async: asyncCombined)
        this.scheduler = Scheduler<T>.current(observer)
    }
    
    /**
     * 使用迭代器I构造被观察者
     * asyncCombined决定是否异步执行每个观察者，false：单线程执行所有观察者，true：每个观察者对应一个线程；观察者接收到的数据是否启用新线程由背压策略决定
     */
    public static func iterable<I>(items: () -> Future<I>, asyncCombined!: Bool = false): Observable<T> where I <: Iterable<T> {
        Observable<T>({=> items().get().iterator()}, asyncCombined: asyncCombined)
    }
    /**
     * 使用迭代器I构造被观察者
     * asyncCombined决定是否异步执行每个观察者，false：单线程执行所有观察者，true：每个观察者对应一个线程；观察者接收到的数据是否启用新线程由背压策略决定
     */
    public static func iterable<I>(items: Future<I>, asyncCombined!: Bool = false): Observable<T> where I <: Iterable<T> {
        iterable<I>({=> items}, asyncCombined: asyncCombined)
    }
    /**
     * 使用迭代器I构造被观察者
     * asyncCombined决定是否异步执行每个观察者，false：单线程执行所有观察者，true：每个观察者对应一个线程；观察者接收到的数据是否启用新线程由背压策略决定
     */
    public static func iterable<I>(items: () -> I, asyncCombined!: Bool = false): Observable<T> where I <: Iterable<T> {
        Observable<T>({=> items().iterator()}, asyncCombined: asyncCombined)
    }
    /**
     * 使用迭代器I构造被观察者
     * asyncCombined决定是否异步执行每个观察者，false：单线程执行所有观察者，true：每个观察者对应一个线程；观察者接收到的数据是否启用新线程由背压策略决定
     */
    public static func iterable<I>(items: I, asyncCombined!: Bool = false): Observable<T> where I <: Iterable<T> {
        iterable<I>({=> items}, asyncCombined: asyncCombined)
    }
    
    /**
     * 将每个Future的结果连接成一个迭代器
     * asyncCombined决定是否异步执行每个观察者，false：单线程执行所有观察者，true：每个观察者对应一个线程；观察者接收到的数据是否启用新线程由背压策略决定
     */
    public static func iterable(futures: () -> Iterable<Future<T>>, asyncCombined!: Bool = false): Observable<T> {
        iterable<Iterator<T>>({=> futures().iterator().map {f => f.get()}}, asyncCombined: asyncCombined)
    }
    /**
     * 将每个Future的结果连接成一个迭代器
     * asyncCombined决定是否异步执行每个观察者，false：单线程执行所有观察者，true：每个观察者对应一个线程；观察者接收到的数据是否启用新线程由背压策略决定
     */
    public static func iterable(futures: Iterable<Future<T>>, asyncCombined!: Bool = false): Observable<T> {
        iterable({=> futures}, asyncCombined: asyncCombined)
    }
    /**
     * 将每个Future的结果连接成一个迭代器
     * asyncCombined决定是否异步执行每个观察者，false：单线程执行所有观察者，true：每个观察者对应一个线程；观察者接收到的数据是否启用新线程由背压策略决定
     */
    public static func iterable(futures: () -> Array<Future<T>>, asyncCombined!: Bool = false): Observable<T> {
        let f: () -> Iterable<Future<T>> = {=> futures().iterator()}
        iterable(f, asyncCombined: asyncCombined)
    }
    /**
     * 将每个Future的结果连接成一个迭代器
     * asyncCombined决定是否异步执行每个观察者，false：单线程执行所有观察者，true：每个观察者对应一个线程；观察者接收到的数据是否启用新线程由背压策略决定
     */
    public static func iterable(futures: Array<Future<T>>, asyncCombined!: Bool = false): Observable<T> {
        let f: () -> Iterable<Future<T>> = {=> futures.iterator()}
        iterable(f, asyncCombined: asyncCombined)
    }
    
    /**
     * 使用数据发射器构造被观察者
     */
    public static func emitter(emit: (Emitter<T>) -> Unit, bufSize!: Int64 = 1, asyncCombined!: Bool = false): Observable<T> {
        iterable({=>
            EmitterIterator<T>(Emitter<T>(qsize: bufSize, fn: emit))
        }, asyncCombined: asyncCombined)
    }

    /**
     * 只有一个数据的被观察者，iterator把item转化成迭代器
     * asyncCombined决定是否异步执行每个观察者，false：单线程执行所有观察者，true：每个观察者对应一个线程；观察者接收到的数据是否启用新线程由背压策略决定
     */
    public static func single(item: () -> Future<T>, iterator!: (T) -> Iterator<T> = {t => SingleIterator<T>(t)},
        asyncCombined!: Bool = false): Observable<T> {
        Observable<T>({=> item().get() |> iterator}, asyncCombined: asyncCombined)
    }
    /**
     * 只有一个数据的被观察者，iterator把item转化成迭代器
     * asyncCombined决定是否异步执行每个观察者，false：单线程执行所有观察者，true：每个观察者对应一个线程；观察者接收到的数据是否启用新线程由背压策略决定
     */
    public static func single(item: Future<T>, iterator!: (T) -> Iterator<T> = {t => SingleIterator<T>(t)},
        asyncCombined!: Bool = false): Observable<T> {
        single({=> item}, iterator: iterator, asyncCombined: asyncCombined)
    }
    /**
     * 只有一个数据的被观察者，iterator把item转化成迭代器
     * asyncCombined决定是否异步执行每个观察者，false：单线程执行所有观察者，true：每个观察者对应一个线程；观察者接收到的数据是否启用新线程由背压策略决定
     */
    public static func single(item: () -> T, iterator!: (T) -> Iterator<T> = {t => SingleIterator<T>(t)},
        asyncCombined!: Bool = false): Observable<T> {
        Observable<T>({=> item() |> iterator}, asyncCombined: asyncCombined)
    }
    /**
     * 只有一个数据的被观察者，iterator把item转化成迭代器
     * asyncCombined决定是否异步执行每个观察者，false：单线程执行所有观察者，true：每个观察者对应一个线程；观察者接收到的数据是否启用新线程由背压策略决定
     */
    public static func single(item: T, iterator!: (T) -> Iterator<T> = {t => SingleIterator<T>(t)},
        asyncCombined!: Bool = false): Observable<T> {
        single({=> item}, iterator: iterator, asyncCombined: asyncCombined)
    }
    
    /**
     * 只有一个数据的被观察者，iterator把item转化成迭代器
     * asyncCombined决定是否异步执行每个观察者，false：单线程执行所有观察者，true：每个观察者对应一个线程；观察者接收到的数据是否启用新线程由背压策略决定
     */
    public static func maybe(item: () -> Future<?T>, iterator!: (?T) -> Iterator<T> = {t => SingleIterator<T>(t)},
        asyncCombined!: Bool = false): Observable<T> {
        Observable<T>({=> item().get() |> iterator}, asyncCombined: asyncCombined)
    }
    /**
     * 只有一个数据的被观察者，iterator把item转化成迭代器
     * asyncCombined决定是否异步执行每个观察者，false：单线程执行所有观察者，true：每个观察者对应一个线程；观察者接收到的数据是否启用新线程由背压策略决定
     */
    public static func maybe(item: Future<?T>, iterator!: (?T) -> Iterator<T> = {t => SingleIterator<T>(t)},
        asyncCombined!: Bool = false): Observable<T> {
        maybe({=> item}, iterator: iterator, asyncCombined: asyncCombined)
    }
    /**
     * 只有一个数据的被观察者，iterator把item转化成迭代器
     * asyncCombined决定是否异步执行每个观察者，false：单线程执行所有观察者，true：每个观察者对应一个线程；观察者接收到的数据是否启用新线程由背压策略决定
     */
    public static func maybe(item: () -> ?T, iterator!: (?T) -> Iterator<T> = {t => SingleIterator<T>(t)},
        asyncCombined!: Bool = false): Observable<T> {
        Observable<T>({=> item() |> iterator}, asyncCombined: asyncCombined)
    }
    /**
     * 只有一个数据的被观察者，iterator把item转化成迭代器
     * asyncCombined决定是否异步执行每个观察者，false：单线程执行所有观察者，true：每个观察者对应一个线程；观察者接收到的数据是否启用新线程由背压策略决定
     */
    public static func maybe(item: ?T, iterator!: (?T) -> Iterator<T> = {t => SingleIterator<T>(t)},
        asyncCombined!: Bool = false): Observable<T> {
        maybe({=> item}, iterator: iterator, asyncCombined: asyncCombined)
    }

    /**
     * 创建空的被观察者，每个观察者只会执行一次onComplete()
     */
    public static func empty(asyncCombined!: Bool = false): Observable<T> {
        Observable<T>({=> EmptyIterator<T>.INSTANCE()}, asyncCombined: asyncCombined)
    }
    
    /**
     * 把所有类型是I的迭代器连接成一个迭代器，
     * asyncCombined决定是否异步执行每个观察者，false：单线程执行所有观察者，true：每个观察者对应一个线程；观察者接收到的数据是否启用新线程由背压策略决定
     */
    public static func concat<I1, I2>(iterables: () -> I2, asyncCombined!: Bool = false): Observable<T> where I2 <: Iterable<I1>,
        I1 <: Iterable<T> {
        Observable<T>({=> iterables().iterator().flatMap {i => i.iterator()}}, asyncCombined: asyncCombined)
    }
    /**
     * 把所有类型是I的迭代器连接成一个迭代器，
     * asyncCombined决定是否异步执行每个观察者，false：单线程执行所有观察者，true：每个观察者对应一个线程；观察者接收到的数据是否启用新线程由背压策略决定
     */
    public static func concat<I1, I2>(iterables: I2, asyncCombined!: Bool = false): Observable<T> where I1 <: Iterable<T>,
        I2 <: Iterable<I1> {
        concat<I1, I2>({=> iterables}, asyncCombined: asyncCombined)
    }
    
    /**
     * 把所有类型是I的迭代器连接成一个迭代器，
     * asyncCombined决定是否异步执行每个观察者，false：单线程执行所有观察者，true：每个观察者对应一个线程；观察者接收到的数据是否启用新线程由背压策略决定
     */
    public static func concat<I1, I2>(iterables: () -> Future<I2>, asyncCombined!: Bool = false): Observable<T> where I2 <: Iterable<I1>,
        I1 <: Iterable<T> {
        concat<I1, I2>({=> iterables().get()}, asyncCombined: asyncCombined)
    }
    /**
     * 把所有类型是I的迭代器连接成一个迭代器，
     * asyncCombined决定是否异步执行每个观察者，false：单线程执行所有观察者，true：每个观察者对应一个线程；观察者接收到的数据是否启用新线程由背压策略决定
     */
    public static func concat<I1, I2>(iterables: Future<I2>, asyncCombined!: Bool = false): Observable<T> where I1 <: Iterable<T>,
        I2 <: Iterable<I1> {
        concat<I1, I2>({=> iterables}, asyncCombined: asyncCombined)
    }
    
    /**
     * 订阅观察者
     */
    public func subscribe(observer: Observer<T>): This {
        this.observer.add(observer)
        this
    }
    /**
     * 总是用当前线程执行观察者
     */
    public func withCurrent(): This {
        this.scheduler = Scheduler<T>.current(this.observer)
        this
    }
    /**
     * 总是用新线程执行观察者
     */
    public func withAlwaysNew(): This {
        this.scheduler = Scheduler<T>.alwaysNew(this.observer)
        this
    }
    /**
     * 单线程执行观察者，policy是背压策略，观察者队列上限是queueSize
     */
    public func withSingle(queueSize: Int64, policy!: BackPressure = BackPressure.Current): This {
        this.scheduler = Scheduler<T>.single(this.observer, queueSize, policy: policy)
        this
    }
    /**
     * 单线程执行观察者，policy是背压策略，观察者队列上限是Int64.Max
     */
    public func withSingle(policy!: BackPressure = BackPressure.Current): This {
        this.scheduler = Scheduler<T>.single(this.observer, policy: policy)
        this
    }
    /**
     * 指定threads数量的线程执行观察者，policy是背压策略
     */
    public func withFixed(threads: Int64, policy!: BackPressure = BackPressure.Current): This {
        this.scheduler = Scheduler<T>.fixed(this.observer, threads, policy: policy)
        this
    }
    /**
     * 指定threads数量的线程执行观察者，观察者队列容量是queueSize，policy是观察者背压策略
     */
    public func withFixed(threads: Int64, queueSize: Int64, policy!: BackPressure = BackPressure.Current): This {
        this.scheduler = Scheduler<T>.fixed(this.observer, threads, queueSize, policy: policy)
        this
    }
    /**
     * 判断是否取消
     */
    public prop isDisposed: Bool {
        get() {
            if(disposed_.load()){
                if(completionOnDisposing.load()){
                    scheduler.schedule(None<T>)
                }
                return true
            }
            false
        }
    }
    /**
     * 取消执行，如果completion是true就向消费者发送完成事件
     */
    public func dispose(completion!: Bool = false): Unit {
        disposed_.store(true)
        completionOnDisposing.store(completion)
    }
    /**
     *  当前线程执行
     */
    public func immediately(): Unit {
        try {
            if (isDisposed) {
                return
            }
            for (item in this.items()) {
                scheduler.schedule(item)
                if (isDisposed) {
                    return
                }
            }
            scheduler.schedule(None<T>)
        } catch (e: Exception) {
            scheduler.schedule(e)
        }
    }
    /**
     * 延迟duration时长执行
     */
    public func delay(duration: Duration): This {
        Timer.once(duration) {
            immediately()
        }
        this
    }
    /**
     * 延迟0时长执行
     */
    public func defer(): This {
        delay(Duration.Zero)
    }
}

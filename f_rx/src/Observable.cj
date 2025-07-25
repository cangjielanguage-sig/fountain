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
    private var iterator = None<Iterator<T>>
    private Observable(private let items: () -> Iterator<T>, 
                       private let asyncCombined!: Bool = false,
                       private let observer!: CombinedObserver<T> = CombinedObserver<T>(async: asyncCombined),
                       private var errorResumer!: ?(Exception) -> ?Iterable<T> = None,
                       private var scheduler!: Scheduler<T> = Scheduler<T>.current(observer),
                       private let disposed_!: AtomicBool = AtomicBool(false),
                       private let completionOnDisposing!: AtomicBool = AtomicBool(false),
                       private var cache!: Cache<T> = EmptyCache<T>()) {
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
    private func replayCached(observer: Observer<T>): Unit {
        spawn{
            for(v in cache) {
                observer.onNext(v)
            }
        }
    }
    /**
     * 添加一个FuncObserver<T>，name是观察者名称，creator接收刚添加的观察者实例，可在此闭包内对观察者做修改
     */
    public func subscribe(name: String, creator: (FuncObserver<T>) -> Unit): This {
        let observer = this.observer.add(name)
        creator(observer)
        replayCached(observer)
        this
    }
    /**
     * 订阅观察者
     */
    public func subscribe(observer: Observer<T>): This {
        this.observer.add(observer)
        replayCached(observer)
        this
    }
    /**
     * 订阅一个观察者，name是观察者名称
     */
    public func subscribe(name: String, observer: Observer<T>): This {
        this.observer.add(name, observer)
        replayCached(observer)
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
     * 指定重放大小
     */
    public func replaySize(capacity!: Int64 = 0): This {
        this.cache = 
        if(capacity <= 0){
            EmptyCache<T>()
        }else{
            QueuedCache<T>(capacity)
        }
        this
    }
    /**
     * 指定错误恢复器，产生或消费数据时如果抛出异常将执行当前指定的恢复器，并使用恢复器返回的迭代器和当前Observable的成员创建新的Observable
     * 多次调用本函数及其重载函数只有最后一个恢复器生效。
     */
    public func setErrorResumer(resumer: (Exception) -> ?Iterable<T>): This {
        this.errorResumer = resumer
        this
    }
    /**
     * 指定错误恢复器，产生或消费数据时如果抛出异常将执行当前指定的恢复器，并继续使用当前Observable的全部成员创建新的Observable
     * 多次调用本函数及其重载函数只有最后一个恢复器生效。
     */
    public func setErrorResumer(resumer: (Exception) -> Unit): This {
        this.setErrorResumer{e => 
            resumer
            this.iterator
        }
    }
    /**
     * 指定错误恢复器，产生或消费数据时如果抛出异常将执行当前指定的恢复器，如果闭包参数返回true会继续使用当前Observable的全部成员创建新的Observable
     * 多次调用本函数及其重载函数只有最后一个恢复器生效
     */
    public func setErrorResumer(resumer: (Exception) -> Bool): This {
        this.setErrorResumer{e => 
            if(resumer(e)){
                this.iterator
            }else{
                None<Iterator<T>>
            }
        }
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
     * 暂停执行，如果completion是true就向消费者发送完成事件
     * 只停止不清空观察者
     */
    public func pause(completion!: Bool = false): Unit {
        disposed_.store(true)
        completionOnDisposing.store(completion)
    }
    private func noObserver(){
        if(this.observer.size == 0){
            disposed_.store(true)
        }
    }
    public func disposeAll(){
        this.observer.clear()
        disposed_.store(true)
    }
    /**
     * 取消指定名称的观察者
     */
    public func dispose(name: String): Unit {
        this.observer.remove(name)
        noObserver()
    }
    /**
     * 取消指定名称的观察者，如果参数observer与已注册观察者不是同一实例会抛出异常
     */
    public func dispose<O>(name: String, observer: O): Unit where O <: Object & Observer<T> {
        this.observer.remove<O>(name, observer)
        noObserver()
    }
    /**
     * 取消指定观察者，如果没有找到相同实例的观察者将什么也不做
     */
    public func dispose<O>(observer: O): Unit where O <: Object & Observer<T> {
        this.observer.remove<O>(observer)
        noObserver()
    }
    /**
     * 取消指定类型的观察者
     */
    public func dispose<O>(): Unit where O <: Observer<T> {
        observer.remove<O>()
        noObserver()
    }
    /**
     *  当前线程执行
     */
    public func immediately(): Unit {
        disposed_.store(false)
        try {
            if (isDisposed) {
                return
            }
            func getIterator(){
                if(let Some(i) <- this.iterator){
                    i
                }else{
                    let iterator = this.items()
                    this.iterator = iterator
                    iterator
                }
            }
            for (item in getIterator()) {
                this.cache.set(item)
                scheduler.schedule(item)
                if (isDisposed) {
                    return
                }
                if(observer.size == 0){
                    noObserver()
                    return
                }
            }
            scheduler.schedule(None<T>)
        } catch (e: Exception) {
            scheduler.schedule(e)
            if(let Some(r) <- errorResumer && let Some(i) <- r(e)){
                Observable<T>({=> i.iterator()}, 
                    asyncCombined: this.asyncCombined,
                    observer: this.observer,
                    errorResumer: this.errorResumer,
                    scheduler: this.scheduler,
                    disposed_: this.disposed_,
                    completionOnDisposing: this.completionOnDisposing,
                    cache: this.cache.new()
                ).defer()
            }
        }
    }
    /**
     * 延迟duration时长执行
     */
    public func delay(duration: Duration): This {
        Timer.once(duration, immediately)
        this
    }
    /**
     * 延迟0时长执行
     */
    public func defer(): This {
        delay(Duration.Zero)
    }
}

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

public class Observable<T> {
    private let observer: CombinedObserver<T>
    private var scheduler: Scheduler<T>
    private let disposed_ = AtomicBool(false)
    private Observable(private let items: () -> Iterator<T>, private let asyncCombined!: Bool = false){
        this.observer = CombinedObserver<T>(async: asyncCombined)
        this.scheduler = Scheduler<T>.current(observer)
    }
    public static func iterable<I>(items: () -> Future<I>, asyncCombined!: Bool = false): Observable<T> where I <: Iterable<T>{
        Observable<T>({=> items().get().iterator()}, asyncCombined: asyncCombined)
    }
    public static func iterable<I>(items: () -> I, asyncCombined!: Bool = false): Observable<T> where I <: Iterable<T> {
        Observable<T>({=> items().iterator()}, asyncCombined: asyncCombined)
    }
    public static func iterable<I>(items: Future<I>, asyncCombined!: Bool = false): Observable<T> where I <: Iterable<T> {
        Observable<T>({=>items.get().iterator()}, asyncCombined: asyncCombined)
    }
    public static func iterable<I>(items: I, asyncCombined!: Bool = false): Observable<T> where I <: Iterable<T> {
        Observable<T>({=>items.iterator()}, asyncCombined: asyncCombined)
    }
    public static func single(item: () -> Future<T>, asyncCombined!: Bool = false): Observable<T> {
        iterable({=>SingleIterator<T>(item().get())}, asyncCombined: asyncCombined)
    }
    public static func single(item: () -> T, asyncCombined!: Bool = false): Observable<T> {
        iterable({=>SingleIterator<T>(item())}, asyncCombined: asyncCombined)
    }
    public static func single(item: Future<T>, asyncCombined!: Bool = false): Observable<T> {
        iterable(SingleIterator<T>(item.get()), asyncCombined: asyncCombined)
    }
    public static func single(item: T, asyncCombined!: Bool = false): Observable<T> {
        iterable(SingleIterator<T>(item), asyncCombined: asyncCombined)
    }
    public static func maybe(item: () -> Future<?T>, asyncCombined!: Bool = false): Observable<T> {
        iterable({=> SingleIterator<T>(item().get())}, asyncCombined: asyncCombined)
    }
    public static func maybe(item: () -> ?T, asyncCombined!: Bool = false): Observable<T> {
        iterable({=> SingleIterator<T>(item())}, asyncCombined: asyncCombined)
    }
    public static func maybe(item: Future<?T>, asyncCombined!: Bool = false): Observable<T> {
        iterable(SingleIterator<T>(item.get()), asyncCombined: asyncCombined)
    }
    public static func maybe(item: ?T, asyncCombined!: Bool = false): Observable<T> {
        iterable(SingleIterator<T>(item), asyncCombined: asyncCombined)
    }
    public static func empty(asyncCombined!: Bool = false): Observable<T> {
        iterable(EmptyIterator<T>(), asyncCombined: asyncCombined)
    }
    
    public func subscribe(observer: Observer<T>): This{
        this.observer.add(observer)
        this
    }
    public func withCurrent(): This {
        this.scheduler = Scheduler<T>.current(this.observer)
        this
    }
    public func withAlwaysNew(): This {
        this.scheduler = Scheduler<T>.alwaysNew(this.observer)
        this
    }
    public func withSingle(queueSize: Int64, policy!: BackPressure = BackPressure.Current): This {
        this.scheduler = Scheduler<T>.single(this.observer, queueSize, policy: policy)
        this
    }
    public func withSingle(policy!: BackPressure = BackPressure.Current): This {
        this.scheduler = Scheduler<T>.single(this.observer, policy: policy)
        this
    }
    public func withFixed(threads: Int64, policy!: BackPressure = BackPressure.Current): This {
        this.scheduler = Scheduler<T>.fixed(this.observer, threads, policy: policy)
        this
    }
    public func withFixed(threads: Int64, queueSize: Int64, policy!: BackPressure = BackPressure.Current): This {
        this.scheduler = Scheduler<T>.fixed(this.observer, threads, queueSize, policy: policy)
        this
    }
    public func isDisposed(): Bool {
        disposed_.load()
    }
    public func dispose(): Unit {
        disposed_.store(true)
    }
    public func delay(duration: Duration): This {
        Timer.once(duration){
            try{
                func isDisposed(){
                    if(this.isDisposed()){
                        scheduler.schedule(None<T>)
                        return true
                    }
                    false
                }
                if(isDisposed()){
                    return
                }
                for(item in this.items()) {
                    scheduler.schedule(item)
                    if(isDisposed()){
                        return
                    }
                }
                scheduler.schedule(None<T>)
            }catch(e: Exception){
                scheduler.schedule(e)
            }
        }
        this
    }
    public func defer(): This {
        delay(Duration.Zero)
    }
}
public class SingleIterator<T> <: Iterator<T> {
    private let got = AtomicBool(false)
    public SingleIterator(private let item: ?T) {}

    public func next(): Option<T> {
        if(got.load()){
            return None<T>
        }
        got.store(true)
        item
    }
}
public class EmptyIterator<T> <: Iterator<T> {
    public func next(): Option<T> {
        None
    }
}
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
    private Observable(private let items: () -> Iterator<T>, private let asyncCombined!: Bool = false) {
        this.observer = CombinedObserver<T>(async: asyncCombined)
        this.scheduler = Scheduler<T>.current(observer)
    }

    public static func iterable<I>(items: () -> Future<I>, asyncCombined!: Bool = false): Observable<T> where I <: Iterable<T> {
        Observable<T>({=> items().get().iterator()}, asyncCombined: asyncCombined)
    }
    public static func iterable<I>(items: Future<I>, asyncCombined!: Bool = false): Observable<T> where I <: Iterable<T> {
        iterable<I>({=> items}, asyncCombined: asyncCombined)
    }
    public static func iterable<I>(items: () -> I, asyncCombined!: Bool = false): Observable<T> where I <: Iterable<T> {
        Observable<T>({=> items().iterator()}, asyncCombined: asyncCombined)
    }
    public static func iterable<I>(items: I, asyncCombined!: Bool = false): Observable<T> where I <: Iterable<T> {
        iterable<I>({=> items}, asyncCombined: asyncCombined)
    }

    public static func iterable(futures: () -> Iterable<Future<T>>, asyncCombined!: Bool = false): Observable<T> {
        iterable<Iterator<T>>({=> futures().iterator().map{f => f.get()}}, asyncCombined: asyncCombined)
    }
    public static func iterable(futures: Iterable<Future<T>>, asyncCombined!: Bool = false): Observable<T> {
        iterable({=> futures}, asyncCombined: asyncCombined)
    }
    public static func iterable(futures: () -> Array<Future<T>>, asyncCombined!: Bool = false): Observable<T> {
        let f: () -> Iterable<Future<T>> = {=> futures().iterator()}
        iterable(f, asyncCombined: asyncCombined)
    }
    public static func iterable(futures: Array<Future<T>>, asyncCombined!: Bool = false): Observable<T> {
        let f: () -> Iterable<Future<T>> = {=> futures.iterator()}
        iterable(f, asyncCombined: asyncCombined)
    }
    

    public static func single(item: () -> Future<T>, iterator!: (T) -> Iterator<T> = {t => SingleIterator<T>(t)},
        asyncCombined!: Bool = false): Observable<T> {
        Observable<T>({=> item().get() |> iterator}, asyncCombined: asyncCombined)
    }
    public static func single(item: Future<T>, iterator!: (T) -> Iterator<T> = {t => SingleIterator<T>(t)},
        asyncCombined!: Bool = false): Observable<T> {
        single({=> item}, iterator: iterator, asyncCombined: asyncCombined)
    }
    public static func single(item: () -> T, iterator!: (T) -> Iterator<T> = {t => SingleIterator<T>(t)},
        asyncCombined!: Bool = false): Observable<T> {
        Observable<T>({=> item() |> iterator}, asyncCombined: asyncCombined)
    }
    public static func single(item: T, iterator!: (T) -> Iterator<T> = {t => SingleIterator<T>(t)},
        asyncCombined!: Bool = false): Observable<T> {
        single({=> item}, iterator: iterator, asyncCombined: asyncCombined)
    }

    public static func maybe(item: () -> Future<?T>, iterator!: (?T) -> Iterator<T> = {t => SingleIterator<T>(t)},
        asyncCombined!: Bool = false): Observable<T> {
        Observable<T>({=> item().get() |> iterator}, asyncCombined: asyncCombined)
    }
    public static func maybe(item: Future<?T>, iterator!: (?T) -> Iterator<T> = {t => SingleIterator<T>(t)},
        asyncCombined!: Bool = false): Observable<T> {
        maybe({=> item}, iterator: iterator, asyncCombined: asyncCombined)
    }
    public static func maybe(item: () -> ?T, iterator!: (?T) -> Iterator<T> = {t => SingleIterator<T>(t)},
        asyncCombined!: Bool = false): Observable<T> {
        Observable<T>({=> item() |> iterator}, asyncCombined: asyncCombined)
    }
    public static func maybe(item: ?T, iterator!: (?T) -> Iterator<T> = {t => SingleIterator<T>(t)},
        asyncCombined!: Bool = false): Observable<T> {
        maybe({=> item}, iterator: iterator, asyncCombined: asyncCombined)
    }

    public static func empty(asyncCombined!: Bool = false): Observable<T> {
        Observable<T>({=> EmptyIterator<T>.INSTANCE()}, asyncCombined: asyncCombined)
    }

    public static func concat<I1, I2>(iterables: () -> I2, asyncCombined!: Bool = false): Observable<T> where I2 <: Iterable<I1>, I1 <: Iterable<T> {
        Observable<T>({=> iterables().iterator().flatMap{i => i.iterator()}}, asyncCombined: asyncCombined)
    }
    public static func concat<I1, I2>(iterables: I2, asyncCombined!: Bool = false): Observable<T> where I1 <: Iterable<T>, I2 <: Iterable<I1> {
        concat<I1, I2>({=> iterables}, asyncCombined: asyncCombined)
    }
    public static func concat<I>(iterables: () -> Array<I>, asyncCombined!: Bool = false): Observable<T> where I <: Iterable<T> {
        concat<I, Array<I>>({=> iterables()}, asyncCombined: asyncCombined)
    }
    public static func concat<I>(iterables: Array<I>, asyncCombined!: Bool = false): Observable<T> where I <: Iterable<T> {
        concat<I>({=> iterables}, asyncCombined: asyncCombined)
    }

    public static func concat<I1, I2>(iterables: () -> Future<I2>, asyncCombined!: Bool = false): Observable<T> where I2 <: Iterable<I1>, I1 <: Iterable<T> {
        concat<I1, I2>({=> iterables().get()}, asyncCombined: asyncCombined)
    }
    public static func concat<I1, I2>(iterables: Future<I2>, asyncCombined!: Bool = false): Observable<T> where I1 <: Iterable<T>, I2 <: Iterable<I1> {
        concat<I1, I2>({=> iterables}, asyncCombined: asyncCombined)
    }
    public static func concat<I>(iterables: () -> Future<Array<I>>, asyncCombined!: Bool = false): Observable<T> where I <: Iterable<T> {
        concat<I, Array<I>>({=> iterables()}, asyncCombined: asyncCombined)
    }
    public static func concat<I>(iterables: Future<Array<I>>, asyncCombined!: Bool = false): Observable<T> where I <: Iterable<T> {
        concat<I>({=> iterables}, asyncCombined: asyncCombined)
    }

    public func subscribe(observer: Observer<T>): This {
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
    public prop isDisposed: Bool {
        get(){
            disposed_.load()
        }
    }
    public func dispose(): Unit {
        disposed_.store(true)
    }
    public func delay(duration: Duration): This {
        Timer.once(duration) {
            try {
                func isDisposed() {
                    if (this.isDisposed) {
                        scheduler.schedule(None<T>)
                        return true
                    }
                    false
                }
                if (isDisposed()) {
                    return
                }
                for (item in this.items()) {
                    scheduler.schedule(item)
                    if (isDisposed()) {
                        return
                    }
                }
                scheduler.schedule(None<T>)
            } catch (e: Exception) {
                scheduler.schedule(e)
            }
        }
        this
    }
    public func defer(): This {
        delay(Duration.Zero)
    }
}

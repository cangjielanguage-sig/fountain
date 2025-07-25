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

public interface Observer<T> {
    /**
     * 处理数据
     */
    func onNext(item: T): Unit
    /**
     * 处理异常
     */
    func onError(ex: Exception): Unit 
    /**
     * 完成函数
     */
    func onComplete(): Unit
}

public class EmptyObserver<T> <: Observer<T> {
    public func onNext(_: T): Unit {}
    public func onError(_: Exception): Unit {}
    public func onComplete(): Unit {}
}
public class FuncObserver<T> <: Observer<T> {
    private var nextFunc: (T) -> Unit = {_ => }
    private var errorFunc: (Exception) -> Unit = {_ => }
    private var completeFunc: () -> Unit = { => }

    public func onNext(item: T): Unit {
        nextFunc(item)
    }
    public func onError(ex: Exception): Unit {
        errorFunc(ex)
    }
    public func onComplete(): Unit {
        completeFunc()
    }
    /**
     * 注册数据处理函数
     */
    public func setNext(callee: (T) -> Unit): This {
        nextFunc = callee
        this
    }
    /**
     * 注册异常处理函数
     */
    public func setError(callee: (Exception) -> Unit): This {
        errorFunc = callee
        this
    }
    /**
     * 注册完成函数
     */
    public func setComplete(callee: () -> Unit): This {
        completeFunc = callee
        this
    }
}
/**
 * 多个观察者的组合，async决定是所有观察者由一个线程执行，还是观察者跟线程一一对应
 */
public class CombinedObserver<T> <: Observer<T> {
    private let observers = ConcurrentHashMap<String, Observer<T>>()
    public CombinedObserver(private let async!: Bool = false){}

    public prop size: Int64 {
        get(){
            observers.size
        }
    }
    public func clear(){
        for((k, _) in observers){
            observers.remove(k)
        }
    }
    /**
     * 添加观察者，name是观察者的名称
     */
    public func add(name: String): FuncObserver<T> {
        let observer = FuncObserver<T>()
        observers.add(name, observer)
        observer
    }
    /**
     * 添加观察者，使用observer的全限定名做观察者名称，
     * 如果如果试图注册FuncObserver<T>会抛出异常，如果同一类型的观察者重复注册会抛出异常
     */
    public func add(observer: Observer<T>): This{
        if(observer is FuncObserver<T>){
            throw ObserverRegistrationException('to invoke add(name: String) or add(name: String, observer: Observer<T>) insdead')
        }
        add(TypeInfo.of(observer).qualifiedName, if(async){
            AsyncObserver<T>(observer)
        }else{
            observer
        })
        this
    }
    /**
     * 注册观察者
     * name是观察者名称，observer是注册的观察者
     */
    public func add(name: String, observer: Observer<T>): This {
        if(observers.addIfAbsent(name, observer).isSome()){
            throw ObserverRegistrationException("observer ${name} already registered")
        }
        this
    }
    /**
     * 删除指定名称的观察者
     */
    public func remove(name: String): Unit {
        observers.remove(name)
    }
    /**
     * 删除指定名称的观察者且已注册观察者与参数observer是同一实例，如果不是同一实例会抛出异常
     */
    public func remove<O>(name: String, observer: O): Unit where O <: Object & Observer<T> {
        if(let Some(o) <- observers.get(name) && let Some(oo) <- (o as Object) && refEq(oo, observer)){
            match(o){
                case x: Object where refEq(x, observer) => observers.remove(name)
                case _ => throw ObserverRegistrationException("registered observer ${name} does not match current specified")
            }
        }
    }
    /**
     * 删除指定观察者，如果没有找到相同实例的观察者将什么也不做
     */
    public func remove<O>(observer: O): Unit where O <: Object & Observer<T> {
        for((n, o) in this.observers) {
            if(let x: Object <- o && refEq(x, observer)){
                this.observers.remove(n)
                return;
            }
        }
    }
    /**
     * 删除指定类型的观察者全部
     */
    public func remove<O>(): Unit where O <: Observer<T> {
        for((n, o) in this.observers where o is O) {
            remove(n)
        }
    }
    private func call(fn: (Observer<T>) -> Unit): Unit {
        for((_, o) in observers){
            fn(o)
        }
    }
    public func onNext(item: T): Unit {
        call{o => o.onNext(item)}
    }
    public func onError(ex: Exception): Unit {
        call{o => o.onError(ex)}
    }
    public func onComplete(): Unit {
        call{o => o.onComplete()}
    }
}
class AsyncObserver<T> <: Observer<T> {
    private let q = ArrayBlockingQueue<T>(1)
    private let e = AtomicOptionReference<Exception>()
    private let c = AtomicBool(false)
    AsyncObserver(private let observer: Observer<T>){
        spawn{
            while(e.load().isNone() && !c.load() && let Some(d) <- q.remove(Duration.millisecond * 100)){
                observer.onNext(d)
            }
            while(let Some(d) <- q.tryRemove()){
                observer.onNext(d)
            }
            if(let Some(ex) <- e.load()){
                observer.onError(ex)
            }
            if(c.load()){
                observer.onComplete()
            }
        }
    }
    public func onNext(item: T): Unit {
        q.add(item)
    }
    public func onError(ex: Exception): Unit {
        e.store(ex)
    }
    public func onComplete(): Unit {
        c.store(true)
    }
}
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
    public func onNext(item: T): Unit {}
    public func onError(ex: Exception): Unit {}
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
    public func onNext(callee: (T) -> Unit): This {
        nextFunc = callee
        this
    }
    /**
     * 注册异常处理函数
     */
    public func onError(callee: (Exception) -> Unit): This {
        errorFunc = callee
        this
    }
    /**
     * 注册完成函数
     */
    public func onComplete(callee: () -> Unit): This {
        completeFunc = callee
        this
    }
}
/**
 * 多个观察者的组合，async决定是所有观察者由一个线程执行，还是观察者跟线程一一对应
 */
public class CombinedObserver<T> <: Observer<T> {
    private let observers = ArrayList<Observer<T>>()
    public CombinedObserver(private let async!: Bool = false){}

    /**
     * 添加观察者
     */
    public func add(): FuncObserver<T> {
        let observer = FuncObserver<T>()
        observers.add(observer)
        observer
    }
    /**
     * 添加观察者
     */
    public func add(observer: Observer<T>): This{
        observers.add(observer)
        this
    }
    private func call(fn: (Observer<T>) -> Unit): Unit {
        for(o in observers) {
            if(async){
                spawn{
                    fn(o)
                }
            }else{
                fn(o)
            }
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
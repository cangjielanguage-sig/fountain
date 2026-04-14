# 最简单用法
```cj
let observable = Observable<Int64>
.iterable([1,2,3])
.subscribe('test', FuncObserver<Int64>().setNext{v => println(v)})
.withCurrent()
.defer()

observable.pause()//暂停产生新数据
// 每次获取下次数据前都会检查内部变量disposed_，disposed_是false的立即结束。dispose()修改disposed_为true。
//disposed_类型是AtomicBool
```
# 初始化方式
1. iterable
    1. 接收一个`Iterable<T>`实例
    2. 接收一个`()->Iterable<T>`实例
    3. 接收一个`()->Future<Iterable<T>>`实例
    4. 接收一个`Future<Iterable<T>>`实例
    5. 接收一个`()->Future<Iterable<T>>`实例
2. emitter
    接收一个`(Emitter<T>) -> Unit`实例
    - `Emitter<T>`
      - onNext(T)
        发送一条数据
      - onComplete()
        发送完成事件
      - onError(Exception)
        发送异常
3. single
    1. 接收一个`T`实例
    2. 接收一个`()->T`实例
    3. 接收一个`Future<T>`实例
    4. 接收一个`()->Future<T>`实例
4. maybe
    1. 接收一个`?T`实例
    2. 接收一个`()->?T`实例
    3. 接收一个`Future<?T>`实例
    4. 接收一个`()->Future<?T>`实例
5. empty
    创建一个空的被观察者
6. concat
    1. 接收一个`Iterable<Iterable<T>>`实例，并把它展开成`Iterator<T>`
    2. 接收一个`()->Iterable<Iterable<T>>`实例，并把它展开成`Iterator<T>`
    3. 接收一个`Future<Iterable<Iterable<T>>`实例，并把它展开成`Iterator<T>`
    4. 接收一个`()->Future<Iterable<Iterable<T>>>`实例，并把它展开成`Iterator<T>`

# 注册观察者
  - `subscribe(Observer<T>)`
    - 可多次调用注册多个观察者
    - 由初始化时的asyncCombined参数决定是否并行执行各个观察者
    - 使用观察者类型全限定名作为名称
  - 有多个重载，还可以为观察者指定名称
# 注销观察者
  - `dispose(completion)`
    强制结束，不再产生新数据。参数决定是否发送完成消息
  - `dispose(name)`
    注销指定名称的观察者
  - `dispose<O>()`
    注销指定类型的全部观察者
  - `dispose<O>(name, O) where O <: Object & Observer<T>`
    注销指定名称和观察者实例，如果注册的观察者与参数不是同一实例会抛异常
  - `dispose<O>(observer: O): Unit where O <: Object & Observer<T>`
    注销指定实例的观察者，如果注册的观察者与参数不是同一实例会抛异常
  - `disposeAll()`
    注销全部观察者
  - `pause(completion!: Bool = false)`
    暂停产生新数据，completion决定是否发送完成事件
  - 如果当前已经没有观察者了将暂停产生新数据，直到注册新的观察者并重新调用启动函数

## 多个观察者

- [多个观察者](doc/多个观察者.md)

## BackPressure

- [BackPressure](doc/BackPressure.md)

## `FuncObserver<T> <: Observer<T>`

- [FuncObserver_T_Observer_T](doc/FuncObserver_T_Observer_T.md)

## `EmptyObserver<T>`

- [EmptyObserver_T](doc/EmptyObserver_T.md)


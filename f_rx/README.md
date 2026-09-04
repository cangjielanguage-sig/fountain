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

    以上每个初始化函数都可以接收命名参数`asyncCombined!: Bool`，用来决定多个观察者是否单独开启线程还是所有观察者都使用一个线程

# 每条数据的处理策略
 1. `withAlwaysNew()`
    总是使用新线程处理每条数据
 2. `withCurrent()`
    总是使用当前线程处理每条数据
 3. `withSingle(...)`
    使用指定背压策略和数据队列长度初始化数据处理策略，一直使用同一个线程处理所有数据
 4. `withFixed(...)`
    使用指定背压策略、数据队列长度和线程数初始化数据处理策略，一直使用这几个线程处理所有数据
# 启动
  1. `delay(Duration)`
     延迟Duration后启动
  2. `defer()`
     0延迟新线程启动
  3. `immediately()`
     当前线程立即启动
# 停止
  - `dispose(completion!: Bool = false)`
    停止当前被观察者，如果参数是true就发送onComplete()事件
# 背压策略
    只有单线程和固定线程数的处理策略才支持背压策略，如果产生新数据时，数据队列已满，则触发背压策略

## BackPressure

 1.  `Discarding`
     丢弃新数据
 2.  `ToDropOldest`
     丢弃队列头的数据
 3.  `AlwaysBlocking`
     一直阻塞
 7.  `Throwing`
     如果队列是满的立即抛出异常
 8.  `Current`
     如果队列是满的就立即使用当前线程处理当前数据
 9.  `NewThread`
     如果队列是满的就立即使用新线程处理当前数据
 10. `Action((()->Unit) -> Unit)`
     如果队列是满的就使用指定函数处理当前数据
 11. `AfterBlockingOrCurrent(Duration, BackPressure<T>)`
     阻塞指定时长后如果队列还是满的就执行指定策略，默认策略是Discarding

# `Observer<T>`
  - `onNext(T)`
    接收一条数据
  - `onComplete()`
    接收完成事件
  - `onError(Exception)`
    接收一个异常


## `FuncObserver<T> <: Observer<T>`

   - `setNext((T) -> Unit)`
     指定接收数据的函数
   - `setNext((Single<T>) -> Unit)`
      `Single<T>`是`SingleIterator<T>`的别名，可以在这个闭包内使用`Iterator<T>`的各种函数。
   - `setError((Exception) -> Unit)`
     指定接收异常的函数
   - `setComplete(() -> Unit)`
     指定接收完成事件的函数


## `EmptyObserver<T>`

   空的观察者

## 错误恢复器
  - `public func setErrorResumer(resumer: (Exception) -> ?Iterable<T>): This`
  - `public func setErrorResumer(resumeIfNone: Bool, resumer: (Exception) -> ?T) : This`
  - `public func setErrorResumer(resumer: (Exception) -> Unit): This`
  - `public func setErrorResumer(resumeIfFalse: Bool, resumer: (Exception) -> Bool): This`
  - `public func setErrorResumer(resumeIfNone: Bool, resumer: (Exception) -> ?(Emitter<T>) -> Unit): This`


## 重放
`Observable.replaySize(capacity)`
启动后如果继续注册观察者会异步重放缓存的数据，缓存数据的数量最大是capacity

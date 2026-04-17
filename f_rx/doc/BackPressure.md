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

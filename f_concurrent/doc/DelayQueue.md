## 延迟队列


### Delayed
```cj
public interface Delayed<T> <: Comparable<T> where T <: Delayed<T> {
    //只要Delayed实例确定了，delayedAt的值就必须是确定的，不能再改变
    prop delayedAt: DateTime

    func compare(other: T): Ordering {
        delayedAt.compare(other.delayedAt)
    }
}
```

### `DelayQueue<T> where T <: Delayed<T>`
```cj
public class DelayQueue<T> <: Queue<T> where T <: Delayed<T> {
    public init()
    //同步函数，返回前通知所有等待数据的线程
    public func add(element: T): Unit
    //非同步函数，返回队列头部数据，不删除队列头
    public func peek(): ?T
    //同步函数，如果队列为空则等待直到非空，否则等待队列头部数据延迟时间后再返回
    //如果等待延迟时间后队列头部数据被其他线程获得，重复这个过程
    public func remove(): ?T
    //同步函数，如果队列为空则等待直到非空或超时，否则等待队列头部数据延迟时间后再返回
    //如果等待延迟时间后队列头部数据被其他线程获得，重复这个过程，
    //每次等待的超时时间为上一次等待的剩余时间
    public func remove(timeout: Duration): ?T
    //非同步函数，获取队列大小
    public prop size: Int64
    //非同步函数，判断队列是否为空
    public func isEmpty(): Bool
    //非同步函数，获取迭代器，返回的迭代器的next函数是同步的
    public func iterator(): Iterator<T>
}
```
## PriorityQueue
优先级队列，容量满时自动扩容
```cj
public class PriorityQueue<T> <: Queue<T> & Iterable<T> & Collection<T> & Growable {
    /**
     * comparator 元素比较器
     * capacity 初始容量
     * overSizePolicy 溢出拒绝策略，fountain::f_base.OverSizePolicy
     */
    public PriorityQueue(
        private let comparator: (T, T) -> Ordering,
        private var capacity!: Int64 = DEFAULT_CAPACITY,
        private let overSizePolicy!: OverSizePolicy<PriorityQueue<T>> = DiscardOverSizePolicy<PriorityQueue<T>>()
    )
    public init(
        comparator: Comparator<T>,
        capacity!: Int64 = DEFAULT_CAPACITY,
        overSizePolicy!: OverSizePolicy<PriorityQueue<T>> = DiscardOverSizePolicy<PriorityQueue<T>>()
    )
    public static func create<T>(
        capacity!: Int64 = DEFAULT_CAPACITY,
        overSizePolicy!: OverSizePolicy<PriorityQueue<T>> = DiscardOverSizePolicy<PriorityQueue<T>>()
    ): PriorityQueue<T> where T <: Comparable<T>
    public static func createReverse<T>(
        capacity!: Int64 = DEFAULT_CAPACITY,
        overSizePolicy!: OverSizePolicy<PriorityQueue<T>> = DiscardOverSizePolicy<PriorityQueue<T>>()
    ): PriorityQueue<T> where T <: Comparable<T>
    public static func create(
        comparator: Comparator<T>,
        capacity!: Int64 = DEFAULT_CAPACITY,
        overSizePolicy!: OverSizePolicy<PriorityQueue<T>> = DiscardOverSizePolicy<PriorityQueue<T>>()
    ): PriorityQueue<T>
    /**
     * current size
     */
    public prop size: Int64
    public func isEmpty(): Bool
    /**
     * add an element
     */
    public func add(x: T): Unit
    /**
     * 扩容
     */
    public func grow(): Unit
    /**
     * offer all elements in values to current queue
     */
    public func add(all!: Collection<T>): Unit
    /**
     * is current heap full? if capacity is not greater than 0, heap is infinity
     */
    private func isFull(): Bool
    /**
     * get element on top
     */
    public func peek(): Option<T>
    /**
     * get and remove element on top
     */
    public func remove(): Option<T>
    public func iterator(): Iterator<T>
    public func removeIf(predicate: (T) -> Bool): Unit
    public func toArray(): Array<T>
}
```

## 扩展Iterator
```cj
//返回的Iterator每次执行next()都创建一个新线程返回一个?Future<?T>，
func async(): Iterator<Future<?T>>
//使用参数比较迭代器的每个元素，返回迭代器中的最小值
func min(cmp: (T, T) -> Ordering): ?T
//使用参数比较迭代器的每个元素，返回迭代器中的最大值
func max(cmp: (T, T) -> Ordering): ?T
//exactly： true，则迭代器的每个元素类型必须是R类型才会返回；exactly: false，则迭代器的每个元素类型必须是R的子类型才会返回；忽略其它元素
func filterType<R>(exactly!: Bool): Iterator<R>
//如果迭代器的每个元素是Iterable<R>，则将当前元素转换为Iterator<R>；如果迭代器元素不是Iterable<R>类型，toThrow是true时会抛出异常，toThrow是false时返回EmptyIterator<T>
func flatten<R>(toThrow!: Bool): Iterator<R>
//用迭代器的每个元素调用collector，把迭代器元素填充到collection
func collect<C>(collection: C, collector: (T, C) -> Unit): C where C <: Collection<T>
//把迭代器转换为Array<T>
func toArray(): Array<T>
//把迭代器转换为ArrayList<T>
func toArrayList(): ArrayList<T>
//把迭代器元素作为key的参数用key返回的K作为HashMap的KEY，将迭代器元素填充到HashMap
func collect<K>(key: (T) -> K): HashMap<K, T> where K <: Hashable & Equatable<K>
//把迭代器元素作为key的参数用key返回的K作为HashMap的KEY，将迭代器元素填充的HashMap
public func groupBy<K>(key: (T) -> K): HashMap<K, ArrayList<T>> where K <: Hashable & Equatable<K>
//返回的实例有一个函数peek，调用peek会返回当前未迭代的值，不消耗任何未迭代值，不影响next()的执行。
public func peekable(): PeekableIterator<T>
```

## PeekableIterator
```cj
public class PeekableIterator<T> <: Iterator<T> & Resource {
    public PeekableIterator(private let itr: Iterator<T>){}

    public func next(): Option<T> 
    public func peek(): ?T 

    /** 关闭底层迭代器（如果实现了 Resource 接口） */
    public func close(): Unit 

    public func isClosed(): Bool 
}
public interface Peekable<T>{
    func peekable(): PeekableIterator<T>
}
extend<T> Iterator<T> <: Peekable<T> 
```
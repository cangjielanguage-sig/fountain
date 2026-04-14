## `SetOp<T>`
所有的Set实现都实现此接口的扩展
```cj
public interface SetOp<T> {
    /**
     * 对两个Set返回交集视图
     */
    func intersection<C>(collection: C): Set<T> where C <: Collection<T>
    /**
     * 对两个Set返回并集视图
     */
    func union<C>(collection: C): Set<T> where C <: Collection<T>
    /**
     * 对两个Set返回差集视图
     */
    func difference<C>(collection: C): Set<T> where C <: Collection<T>
}
```

## `ResourceManager<R> where R <: Resource`
```cj
/**
 * 构造函数接收一个返回Resource实现的闭包，call函数执行fn，fn结束时关闭new闭包返回的实例
 */
public struct ResourceManager<R> where R <: Resource {
    public init(new: () -> R)
    public func call<T>(fn: (R) -> T): T 
}

```

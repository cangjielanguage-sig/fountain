## 顶级函数resource
```cj
//代替try-with-resource，fn的参数是res，区别是本函数会返回fn的返回。
public func resource<R, T>(res: R, fn: (R) -> T): T where R <: Resource
```

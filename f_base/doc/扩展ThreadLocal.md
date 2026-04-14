## 扩展ThreadLocal
```cj
//如果当前ThreadLocal有值就返回当前值，否则调用fn，将fn的返回值存入当前ThreadLocal，并返回刚存入的值
func getOrCompute(fn: () -> T): T
//清除当前ThreadLocal的值
func remove(): Unit
```

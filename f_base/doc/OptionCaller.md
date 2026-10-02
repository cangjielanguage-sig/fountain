## OptionCaller
```cj
public class OptionCaller<T, R> {
    public OptionCaller(
        private let option: ?T,
        private let someCallee: (T) -> R,
        private var noneCallee!: ?() -> R = None<() -> R>
    ) {}
    //修改noneCallee
    public func none(callee: () -> R) 
    //如果option是Some，执行someCallee，否则执行noneCallee，如果noneCallee是None，则返回None
    public func call(): ?R 
    //同call
    public operator func ()(): ?R 
}
```

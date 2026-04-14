## Result<T, E>
```cj
public enum Result<T, E> {
    | Ok
    | Ok(T)
    | Err
    | Err(E)
    | NoResult
    //当前Result是不是Ok
    public prop isOk: Bool 
    //当前Result是不是Err
    public prop isErr: Bool 
    //当前Result是不是NoResult
    public prop isNoResult: Bool 
    //当前Result是否包含错误值，只有是Err(E)时才返回true
    public prop withE: Bool
    //当前Result是否包含正确的值，只有是Ok(T)时才返回true
    public prop withValue: Bool 
    //是Ok(T)时返回Some(T)，其它情况返回None<T>
    public func result(): ?T 
    //是Err(E)时返回Some(E)，其它情况返回None<E>
    public func err(): ?E 
    //将当前Result转换为Result<U, E>，当前Result是Ok(T)时执行参数f，
    public func mapValue<U>(f: (T) -> Result<U, E>): Result<U, E> 
    /**
     * 将当前Result转换为Result<U, E>，当前Result是Err(E)时执行参数f，
     * 当前Result是Ok(x: U)时返回Ok(x)，其它Ok值返回Ok
     * 其它情况返回同样的枚举值
     */
    public func mapError<U>(f: (E) -> Result<U, E>): Result<U, E> 
    //忽略数据和错误信息，只返回Ok Err NoResult
    public func ignore(): Result<T, E> 
    //当前Result 是Ok(x)时执行predicate，且返回true时返回当前Result，其它情况返回NoResult
    public func filterValue(predicate: (T) -> Bool): Result<T, E> 
    //当前Result是Err(x)时执行predicate，且返回true时返回当前Result，其它情况返回NoResult
    public func filterError(predicate: (E) -> Bool): Result<T, E> 
    //当前Result的isOk返回true时返回当前Result，否则返回NoResult
    public func filterOk(): Result<T, E> 
    //当前Result的isErr返回true返回当前Result，否则返回NoResult
    public func filterErr(): Result<T, E>
    //当前Result是Err(E)时返回当前Result，否则返回NoResult
    public func filterWithE(): Result<T, E>
    //当前Result是Ok(T)时返回当前Result，否则返回NoResult
    public func filterWithValue(): Result<T, E>
    //如果当前Result是Ok(x: Result<U, E>)返回x，其它情况原样返回
    public func flatten<U>(): Result<U, E> 
    //如果当前Result是Ok(x: U)，返回Ok(x)，是Ok(x)，但是x不是类型U返回Ok，其它情况原样返回
    public func transpose<U>(): ?Result<U, E> 
    //如果当前Result是Ok(x)，返回x，其它情况返回default
    public func orDefault(default: T): T 
    //如果当前Result是Ok(x)，返回x，其它情况返回fn的返回值
    public func orElse(fn: () -> T): T 
    //如果当前Result是Ok(x)，返回x，其它情况返回fn的返回值
    public func orElse(fn: () -> ?T): ?T 
}
```

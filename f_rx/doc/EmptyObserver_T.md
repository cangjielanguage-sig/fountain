## `EmptyObserver<T>`
   空的观察者

# 错误恢复器
  - `public func setErrorResumer(resumer: (Exception) -> ?Iterable<T>): This`
  - `public func setErrorResumer(resumeIfNone: Bool, resumer: (Exception) -> ?T) : This`
  - `public func setErrorResumer(resumer: (Exception) -> Unit): This`
  - `public func setErrorResumer(resumeIfFalse: Bool, resumer: (Exception) -> Bool): This`
  - `public func setErrorResumer(resumeIfNone: Bool, resumer: (Exception) -> ?(Emitter<T>) -> Unit): This`


# 重放
`Observable.replaySize(capacity)`
启动后如果继续注册观察者会异步重放缓存的数据，缓存数据的数量最大是capacity

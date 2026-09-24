## 扩展Option
```cj
//用当前Option实例化为只有一个元素的迭代器，这个迭代在首次调用next函数时函数返回值取决于Option是Some还是None
func iterator(): Iterator<T>
//如果Option是Some则用Some包含的值调用fn，则fn的返回值就是call的返回值，否则call返回None
func call<R>(fn: (T) -> R): ?R
//如果Option是Some则用Some包含的值和right作参数调用fn，则fn的返回值就是call的返回值，否则call返回None
func call<A, R>(right: A, fn: (T, A) -> R): ?R

//fn和当前Option作为参数初始化OptionCaller
func caller<R>(fn: (T) -> R): OptionCaller<T, R>
//fn、right和当前Option作为参数初始化OptionCaller
func caller<A, R>(right: A, fn: (T, A) -> R): OptionCaller<T, R>
//当前Option如果是Some(x: U)，则转换为Result.Ok(x)；如果是Some但是类型不是U，返回None；如果是None，返回NoResult
func toResult<U, E>(): ?Result<U, E>
//当前Option如果是Some，调用fn转换为U，并用返回值实例化为Result类型，否则返回None
func toResult<U, E>(fn: (T) -> U): ?Result<U, E>
//当前Option如果是Some，调用fn转换为?U，如果返回了Some(x)，则将Some的值实例化为Result<U, E>.Ok(x)， 否则返回None；如果是None，则返回NoResult
func toResult<U, E>(fn: (T) -> ?U): ?Result<U, E>
//当前Option如果是Some(x: U)，返回Result<U, E>.Ok(x)，如果是Some，但值不是类型U，会抛出异常；否则返回Result<U, E>.NoResult
func toResult<U, E>(fn: () -> Exception): Result<U, E>
//将当前Option包装为Result.Ok(this)
func wrapResult<E>(): Result<?T, E>
``

## `FuncObserver<T> <: Observer<T>`
   - `setNext((T) -> Unit)`
     指定接收数据的函数
   - `setNext((Single<T>) -> Unit)`
      `Single<T>`是`SingleIterator<T>`的别名，可以在这个闭包内使用`Iterator<T>`的各种函数。
   - `setError((Exception) -> Unit)`
     指定接收异常的函数
   - `setComplete(() -> Unit)`
     指定接收完成事件的函数

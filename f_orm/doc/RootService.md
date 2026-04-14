## `RootService`
业务层的类型必须实现以下接口
```cj
public interface RootService {
    /**
     * 用参数name指定的驱动名创建一个SqlExecutor实例，每个线程每个驱动名对应一个SqlExecutor实例
     */
    func executor(name: String): SqlExecutor
    /**
     * 使用默认的驱动名得到一个SqlExecutor实例，每个线程每个驱动名对应一个SqlExecutor实例
     */
    func executor(): SqlExecutor
}
```

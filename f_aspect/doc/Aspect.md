## `Aspect`
  - 导入宏：`import fountain::f_aspect.Aspect`
```cj
/**
 * 所有切面必须实现本接口，且必须被@AspectRoute修饰。
 */
public interface Aspect {
    /**
     * 最先执行，先于around 原函数体 after throwing final，默认什么也不做
     */
    func before(funcInfo: InvocationFuncInfo): Unit 
    /**
     * 在around返回后执行，默认是立即返回result
     */
    func after(funcInfo: InvocationFuncInfo, result: Any): Any 
    /**
     * 在before返回后after之前执行，原函数在around内部某个时机执行，由开发者控制，默认是立即执行原函数体
     */
    func around(funcInfo: InvocationFuncInfo, point: (Array<Any>) -> Any): Any 
    /**
     * 在before、原函数体、around、after任意一个抛出异常时执行，默认返回参数e
     */
    func throwing(funcInfo: InvocationFuncInfo, e: Exception): Exception 
    /**
     * 在before、原函数体、around、after、throwing执行完成后执行，默认什么也不做
     */
    func final(funcInfo: InvocationFuncInfo): Unit {}
    /**
     * 开发者可以覆盖这个函数自由定义切面，默认是按照before around 原函数体 after throwing final这个顺序执行
     * before around 原函数体 after 在try块执行
     * throwing在catch块执行，会在before around 原函数体 after 等任意一步抛出异常时执行
     * final在finally块执行，会在前面各步结束后执行
     */
    func proceed(funcInfo: InvocationFuncInfo, point: (Array<Any>) -> Any): Any 
}
```

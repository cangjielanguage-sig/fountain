## `LoopCondition`
```cj
public class LoopCondition<I, T> where I <: Iterable<T> {
    LoopCondition(private let values: I, private let executor: SqlExecutor)
    /**
     * LoopCondition构造的SQL片段左边插入left，右面插入right
     */
    public func wrap(left: String, right: String): LoopCondition<I, T> 
    /**
     * LoopCondition构造的SQL片段左边插入left
     */
    public func wrapLeft(left: String): LoopCondition<I, T> 
    /**
     * LoopCondition构造的SQL片段右面插入right
     */
    public func wrapRight(right: String): LoopCondition<I, T> 
    /**
     * LoopCondition构造的SQL片段，左边裁剪left，右边裁剪right
     */
    public func trim(left: String, right: String): LoopCondition<I, T> 
    /**
     * LoopCondition构造的SQL片段，左边裁剪left
     */
    public func trimLeft(left: String): LoopCondition<I, T> 
    /**
     * LoopCondition构造的SQL片段，右边裁剪right
     */
    public func trimRight(right: String): LoopCondition<I, T> 
    /**
     * 遍历每个迭代器元素所得到的SQL片段后面都追加本函数实参
     */
    public func delimiter(d: String): LoopCondition<I, T> 
    /**
     * SQL参数是否添加到SQL中
     */
    public prop argInSql: LoopCondition<I, T> 
    /**
     * 遍历迭代器元素和当前的元素索引作为闭包参数，如果闭包返回true就执行partial闭包，忽略返回false的那些元素
     */
    public func condition(cond: (T, Int64) -> Bool): LoopCondition<I, T> 
    /**
     * 如果condition闭包返回true，就用迭代器元素和元素索引作为闭包参数，返回的元组第一个元素是SQL片段，第二个元素是SQL参数
     */
    public func partial(partial: (T, Int64) -> (String, Any)): LoopCondition<I, T> 
    /**
     * 如果condition闭包返回true，就用迭代器元素和元素索引作为闭包参数，返回的是SQL参数
     */
    public func partial(partial: (T, Int64) -> Any): LoopCondition<I, T> 
    /**
     * 遍历迭代器并执行以上闭包
     */
    public func done(): String
}
```

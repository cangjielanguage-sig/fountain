## `ChooseCondition`
```cj
/**
 * 只向SQL添加注册进来的第一个条件闭包是true的SQL片段
 */
public class ChooseCondition {
    public ChooseCondition(private let executor: SqlExecutor) {}
    /**
     * 调用一次确认将SQL参数添加到SQL中，不调用则是将SQL参数添加到SQL参数列表并向SQL添加?作为参数占位符
     */
    public prop argInSql: ChooseCondition 
    /**
     * SQL条件闭包，可以添加多个condition和partial，condition和partial必须一一对应
     */
    public func condition(condition: () -> Bool): ChooseCondition 
    /**
     * 返回的元组第一个元素是添加到SQL的片段，第二个元素是SQL参数。可以添加多个condition和partial，condition和partial必须一一对应
     */
    public func partial(partial: () -> (String, Any)): ChooseCondition 
    /**
     * 返回的是SQL参数。可以添加多个condition和partial，condition和partial必须一一对应
     */
    public func partial(partial: () -> Any): ChooseCondition 
    /**
     * 返回的是SQL片段。可以添加多个condition和partial，condition和partial必须一一对应
     */
    public func partial(partial: () -> String): ChooseCondition 
    /**
     * 当没有condition是true时执行otherwise，只有添加的最后一个otherwise生效
     * 返回的元组第一个元素是添加到SQL的片段，第二个元素是SQL参数。
     */
    public func otherwise(partial: () -> (String, Any)): ChooseCondition 
    /**
     * 当没有condition是true时执行otherwise，只有添加的最后一个otherwise生效
     * 返回的是SQL片段。
     */
    public func otherwise(partial: () -> String): ChooseCondition 
    /**
     * 当没有condition是true时执行otherwise，只有添加的最后一个otherwise生效
     * 返回的是SQL参数。
     */
    public func otherwise(partial: () -> Any): ChooseCondition 
    /**
     * 执行添加进来的闭包，将第一个返回true的condition对应的partial添加到SQL。
     * 如果没有condition返回true，执行othersize，如果没有指定otherwise则不添加新的SQL片段也没有参数
     */
    public func done(): String 
}
```

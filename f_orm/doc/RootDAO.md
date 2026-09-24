## `RootDAO`
```cj
/**
 * 所有的DAO接口都要继承本接口
 */
public interface RootDAO {
    /**
     * 本接口函数不必实现，所有DAO都是SqlExecutor的扩展，SqlExecutor已经提供了相同声明的属性，
     * 且SqlExecutor已经实现本接口，故任意DAO接口可以直接调用本属性
     */
    prop executor: SqlExecutor
    /**
     * 所有的arg函数都会返回'?'作为SQL参数占位符
     * 对于Option类型的arg函数形参，会从Some(x)提取参数值，如果arg函数实参是None会添加null参数值
     */
    func arg(value: Bool): String
    func arg(value: ?Bool): String
    func arg(value: Int8): String
    func arg(value: ?Int8): String
    func arg(value: UInt8): String
    func arg(value: ?UInt8): String
    func arg(value: Int16): String
    func arg(value: ?Int16): String
    func arg(value: UInt16): String
    func arg(value: ?UInt16): String
    func arg(value: Int32): String
    func arg(value: ?Int32): String
    func arg(value: UInt32): String
    func arg(value: ?UInt32): String
    func arg(value: Int64): String
    func arg(value: ?Int64): String
    func arg(value: UInt64): String
    func arg(value: ?UInt64): String
    func arg(value: Float16): String
    func arg(value: ?Float16): String
    func arg(value: Float32): String
    func arg(value: ?Float32): String
    func arg(value: Float64): String
    func arg(value: ?Float64): String
    func arg(value: BigInt): String
    func arg(value: ?BigInt): String
    func arg(value: Decimal): String
    func arg(value: ?Decimal): String
    func arg(value: Rune): String
    func arg(value: ?Rune): String
    func arg(value: String): String
    func arg(value: ?String): String
    func arg(value: InputStream): String
    func arg(value: ?InputStream): String
    func arg(value: Duration): String
    func arg(value: ?Duration): String
    func arg(value: DateTime): String
    func arg(value: ?DateTime): String
    func arg(value: Array<Byte>): String
    func arg(value: ?Array<Byte>): String
    /**
     * 参数类型是fountain::f_data.Data，可以从Data的各个实现类型得到具体的SQL参数值
     */
    func arg(value: Data): String
    func arg(value: Any): String
    /**
     * 用于SQL表达式IN
     */
    func arg<I, T>(value: I): String where I <: Iterable<T>
    /** 
     * 添加SQL实参null 
     */
    func argNull(): String 
    /**
     * 动态SQL条件
     * @param condition 为true时把partial 添加到SQL，value添加到SQL参数列表
     */
    func meet(condition: Bool, partial: String, value: Any): String
    /**
     * 动态SQL条件
     * @param condition 为true时把partial 添加到SQL，value()的返回值添加到SQL参数列表
     */
    func meet(condition: Bool, partial: String, value: () -> Any): String
    /**
     * ChooseCondition实例会将第一个返回true的条件闭包所对应的SQL和参数闭包添加到构造的SQL末尾和SQL参数列表，忽略其它闭包
     */
    prop choose: ChooseCondition
    /**
     * LoopCondition用来遍历values并执行添加到LoopCondition的闭包，用values内的元素构造SQL片段
     */
    func loop<I, T>(values: I): LoopCondition<I, T> where I <: Iterable<T>
    /**
     * 遍历value，构造IN (?, ?, ...)
     */
    func IN<I, T>(value: I): String where I <: Iterable<T>
    /**
     * 遍历value，构造NOT IN (?, ?, ...)
     */
    func NOT_IN<I, T>(value: I): String where I <: Iterable<T>
    /**
     * 返回一条SELECT SQL，并用返回的SQL构造EXISTS (SELECT ...)
     */
    func EXISTS(exists: () -> String): String
    /**
     * 返回一条SELECT SQL，并用返回的SQL构造NOT EXISTS (SELECT ...)
     */
    func NOT_EXISTS(exists: () -> String): String
    /**
     * 裁剪闭包返回的字符串开头结尾的','，并用这个SQL构造SET子句
     */
    func SET(partial: () -> String): String
    /**
     * 裁剪闭包返回的字符串开头结尾的and和or（and和or不分大小写），并用这个SQL构造WHERE子句。
     */
    func WHERE(partial: () -> String): String
    /**
     * 裁剪闭包返回的字符串开头结尾的and和or（and和or不分大小写），并用这个SQL构造WHERE子句。
     * 闭包内调用的每两个meet choose返回的SQL片段中间都会用delimiter分割
     */
    func WHERE(delimiter: String, partial: () -> String): String
    /**
     * 裁剪partial开头的prefix，结尾的suffix，将裁剪后的字符串追加到当前构造的SQL后面
     */
    func trim(prefix!: String, suffix!: String, partial!: () -> String): String
}
```

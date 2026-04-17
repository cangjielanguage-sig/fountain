## `SqlExcutor`
```cj
public class SqlExecutor <: Resource & RootDAO {
    /**
     * 如果是select开头就返回true
     */
    public prop isReadOnly: Bool
    /**
     * DAO接口必须声明相同的属性，不必真的提供实现。所有的DAO都是SqlExecutor的扩展
     * SqlExecutor提供的实现是返回自身
     */
    public prop executor: SqlExecutor
    public func isClosed(): Bool
    public func close(): Unit
    /**
     * 启动新事务
     */
    public func newTxAndBegin(
        propagation!: Propagation = ORMConfig.getTransactionPropagation(driverName: driverName),
        isoLevel!: ?TransactionIsoLevel = ORMConfig.getTransactionLevel(driverName: driverName),
        accessMode!: ?TransactionAccessMode = ORMConfig.getTransactionAccessMode(driverName: driverName),
        deferrableMode!: ?TransactionDeferrableMode = ORMConfig.getTransactionDeferrableMode(driverName: driverName)
    ): SqlExecutor
    /**
     * 提交
     */
    public func commit(): Unit
    /**
     * 回滚
     */
    public func rollback(): Unit
    /**
     * 回滚到指定的savepoint
     */
    public func rollback(savepoint: String): Unit
    /**
     * 异常类型是e的实际类型时不回滚而是执行提交，除非提交时又发生异常
     */
    public func noRollbackFor(e: Exception): Exception
    /**
     * 异常类型是e的实际类型时才执行回滚
     */
    public func rollbackFor(e: Exception): Exception
    /**
     * 执行本函数前必须先启动一个事务，然后执行callee，最后commit。
     * 本函数不执行回滚。
     */
    public func callAndCommit<T>(callee: () -> T): T
    /**
     * 为当前事务指定savepoint
     */
    public func save(savepoint: String): Unit
    /**
     * 释放指定的savepoint
     */
    public func release(savepoint: String): Unit
    /**
     * 执行udpate，当前SqlExecutor维持的SQL必须是UDPATE，返回更新的行数
     */
    public prop update: Int64
    /**
     * 执行delete，当前SqlExecutor维持的SQL必须是delete，返回删除的行数
     */
    public prop delete: Int64
    /**
     * 执行insert，当前SqlExecutor维持的SQL必须是insert，否则会出错，返回刚插入的主键
     */
    public prop insert: Int64
    /**
     * 返回第一行列索引是0的那一列
     */
    public func singleFirst<T>(): Option<T>
    /**
     * 返回第一行列索引是index的那一列
     */
    public func singleFirst<T>(index: Int64): Option<T>
    /**
     * 返回第一行列名或别名是column的那一列
     */
    public func singleFirst<T>(column: String): Option<T>
    /**
     * 返回索引是0的那一列的全部查询结果
     */
    public func singleList<T>(): ArrayList<T>
    /**
     * 返回列索引是index的那一列的全部查询结果
     */
    public func singleList<T>(index: Int64): ArrayList<T>
    /**
     * 返回列名或列别名是column的那一列的全部查询结果
     */
    public func singleList<T>(column: String): ArrayList<T>
    /**
     * 返回的迭代器可以遍历列索引是0的那一列的全部查询结果
     */
    public func singleIterator<T>(): Iterator<T>
    /**
     * 返回的迭代器可以遍历列索引是index的那一列的全部查询结果
     */
    public func singleIterator<T>(index: Int64): Iterator<T>
    /**
     * 返回的迭代器可以遍历列名或列别名是column的那一列的全部查询结果
     */
    public func singleIterator<T>(column: String): Iterator<T>
    /**
     * 按照指定的映射类型将第一行查询结果映射为泛型类型并返回，如果没有查到数据返回None<T>
     */
    public func first<T>(mappers: QueryMappers<T>): Option<T>
    /**
     * 将第一行查询结果映射为泛型类型并返回，如果没有查到数据返回None<T>
     */
    public func first<T>(): Option<T> where T <: QueryMappersInit<T>
    /**
     * 将查到的第一行数据映射为HashMap，KEY是select 列名
     */
    public func firstToMap(): Map<String, Any>
    /**
     * 将查到的所有数据映射为泛型类型T，并返回查询结果的ArrayList<T>
     */
    public func list<T>(mappers: QueryMappers<T>): ArrayList<T>
    /**
     * 将查到的所有数据映射为泛型类型T，并返回查询结果的ArrayList<T>
     */
    public func list<T>(): ArrayList<T> where T <: QueryMappersInit<T>
    /**
     * 将查到的所有数据映射为HashMap，Map的KEY是select列名，并返回查询结果的ArrayList<T>
     */
    public func mapList(): ArrayList<HashMap<String, Any>>
    /**
     * 将查到的所有数据映射为泛型类型T，并返回一个迭代器
     */
    public func iterator<T>(mappers: QueryMappers<T>): QueryResultIterator<T>
    /**
     * 将查到的所有数据映射为泛型类型T，并返回一个迭代器
     */
    public func iterator<T>(): Iterator<T> where T <: QueryMappersInit<T>
    /**
     * 
     */
    public func one<T>(mappers: QueryMappers<T>): Option<T>
}
```

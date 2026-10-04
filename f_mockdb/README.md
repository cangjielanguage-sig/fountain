# mockdb
`fountain::f_mockdb`是一个数据库驱动模拟工具。
---

## 导入

```cj
import fountain::f_mockdb.*
```


## 使用

```cj
import fountain::f_mockdb.*
private let _ = {=>
    MOCKDB.clear()//每个用例开头清一次夹具（行、列信息、toThrowOn* 标志、metadata、lastInsertId、rowCount），不动 execution
    MOCKDB.execution = {sql: String, args: ArrayList<Any> =>
        //在此处添加各种模拟结果，可以用 sql 和 args 参数做判断并调用以下函数决定向 mockdb 填充什么信息
        let row: Array<Any> = [...]
        MOCKDB.addQueryResultRow(row)//添加一行查询结果，数组元素的顺序就是 select 子句的列顺序
        MOCKDB.addQueryResultColumnInfo(//添加 select 子句的列信息
            name: 'column_name',//当前列名
            nullable: false,//当前列是否允许为空
            typeName: 'SqlVarchar'//当前列的类型名，列类型名参考 sql.database.sql 的文档。对于 fountain::f_orm，typeName 可以是 SqlDataType，也可以是仓颉类型名
        )
        let rows: ArrayList<Array<Any>> = MOCKDB.getQueryResultRows()//得到本次执行的行
        let columnInfos: Array<ColumnInfo> = MOCKDB.queryResultColumnInfos//得到 select 子句的列信息
        MOCKDB.lastInsertId = 1//指定最后插入的数据行的ID，默认是0。public static mut prop lastInsertId: Int64
        MOCKDB.rowCount = 1//指定执行 insert update delete 影响的行数，默认是0。public static mut prop rowCount: Int64
        MOCKDB.toThrowOnExecuting = false//决定执行当前SQL时是否抛出异常，默认是false；置 true 时不执行本夹具、直接抛 MockDbException。public static mut prop toThrowOnExecuting: Bool
        MOCKDB.metadata = {=>//指定数据库连接 Connection 的元数据，默认是空的 HashMap<String, String>；Connection.getMetaData() 返回的是副本
            let map = HashMap<String, String>()
            ....
            map
        }()//public static mut prop metadata: Map<String, String>
    }
}()
```

## 时序与约定

- **一次执行一份结果**：`MockStatement.query()` / `update()` 先清空上一次的行与列信息，再执行 `execution`，然后把结果**快照**交给 `QueryResult`。夹具请在 `execution` **内**写行/列信息（写在外部会被清掉）；因此同一线程（含事务内）多次查询互不串数据。
- **参数槽**：`set` / `setNull` 的参数在该次执行结束后清空 ⇒ 复用同一个 `Statement` 时每次执行前都要重新绑定；参数索引为负、或 **≥ SQL 里 `?` 占位符个数**（按真驱动口径定上界，避免大索引补出天量占位符）都抛 `SqlException`。**参数值口径：`args[i]` 是 `None<Any>` 就按 SQL NULL 处理**——未绑定的位置（`set` 补出的空位）与 `setNull` 写入的值都是 `None<Any>`，mock 不区分二者、也不做「参数未设置」完备性校验（真驱动会在执行时报错）；夹具断言「显式 NULL」直接判 `args[i].isNone()` 即可。
- **结果集契约**：`getOrNull<T>` 只在「该列是 SQL NULL」时返回 `None`；行未准备好（未 `next()`）或列索引越界抛 `SqlException`；列值类型与 `T` 不符也抛 `SqlException`。`get<T>` = `getOrNull` + `getOrThrow`，真 NULL 时抛 `NoneValueException`。
- **列信息**：`MockColumnInfo` 的 `displaySize` 返回 `Int64.Max`、`length` / `scale` 返回 `0`（std 契约里「无限制 / 列大小不适用 / 无小数」的取值）。
- **关闭语义**：`close()` 之后 `isClosed()` 为 `true`、`Connection.state` 为 `Closed`（重复关闭幂等）；**关连接不再清夹具**，夹具用 `MOCKDB.clear()` 显式管理。
- **输出开关**：mock 内部动作（`open`、`setOption`、事务各步、未设置夹具时的 `EMPTY_EXECUTION`）默认**不输出**；排查「夹具为什么没生效」时置 `MOCKDB.verbose = true`。
- **`MOCKDB` 公开成员**：`clear()`（清全部夹具）、`clearQueryResult()`（只清行与列信息）、`verbose`、`currentThreadId`、`execution`、`addQueryResultRow`、`addQueryResultColumnInfo`、`getQueryResultRows`、`queryResultColumnInfos`、`metadata`、`lastInsertId`、`rowCount`、`toThrowOn*` 系列。
- **事务**：`MockTransaction` 有最小状态机 —— 未 `begin()` 就 `commit` / `rollback` / `save` / `release`、重复 `begin()`、事务已结束后再 `commit` / `rollback`，都抛 `SqlException`。失败模拟仍用 `toThrowOnBeginning` / `toThrowOnCommitting` / `toThrowOnReleasing(sp)` / `toThrowOnRollbacking` / `toThrowOnRollbackingSavePoint(sp)` / `toThrowOnSavingSavePoint(sp)`（读写成对），抛出的 `MockDbException` 带出错步骤（含 SQL 文本或 savepoint 名）。
- **驱动入口参数**：`MockDriver.open(connectionString, opts)` 把连接串记在 `MockDatasource.connectionString`，`setOption` 累积到 `MockDatasource.options`（读取返回副本）⇒ 用例可以断言参数确实传到了驱动。

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
    MOCKDB.execution = {sql: String, args: Array<Any> =>
        //在此处添加各种模拟结果，可以用sql 和args参数做判断并调用以下函数决定向mockdb填充什么信息
        let row: Array<Any> = [...]
        MOCKDB.addQueryResultRow(row)//添加一行查询结果，数组元素的顺序就是select子句的列顺序
        MOCKDB.addQueryResultColumnInfo(//添加select子句的列信息
            name: 'column_name',//当前列名
            nullable: false,//当前列是否允许为空
            typeName: 'SqlVarchar'//当前列的类型名，列类型名参考sql.database.sql的文档。对于fountain::f_orm，typeName可以是SqlDataType，也可以是仓颉类型名
        )
        let rows: Array<Any> = MOCKDB.getQueryResultRows()//得到查询结果
        let columnInfos: Array<ColumnInfo> = MOCKDB.queryResultColumnInfos//得到select子句的列信息
        MOCKDB.lastInsertId = 1//指定最后插入的数据行的ID，默认是0。public static mut prop lastInsertId: Int64
        MOCKDB.rowCount = 1//指定执行insert update delete 影响的行数，默认是0。public static mut prop rowCount: Int64
        MOCKDB.toThrowOnExecuting = false//决定执行当前SQL时是否抛出异常，默认是false。public static mut prop toThrowOnExecuting: Bool
        MOCKDB.metadata = {=>//指定数据库连接Connection的元数据，默认是空的HashMap<String, String>
            let map = HashMap<String, String>()
            ....
            map
        }()//public mut prop metadata: Map<String, String>
        MOCKDB.toThrowOnBeginning = false//指定事务开始时是否抛出异常，默认是false。public static mut prop toThrowOnBeginning: Bool
        MOCKDB.toThrowOnCommitting = false//指定事务提交时是否抛出异常，默认是false。public static mut prop toThrowOnCommitting: Bool
        MOCKDB.toThrowOnReleasing('savepoint', false)//指定事务释放savepoint时是否抛出异常。
        MOCKDB.toThrowOnReleasing('savepoint')//得到指定事务放的savepoint是否抛出异常，如果返回true则执行这个savepoint时抛出异常，默认返回false。public static func toThrowOnReleasing(savepoint: String): Bool
        MOCKDB.toThrowOnRollbacking = false//指定事务回滚时是否抛出异常，默认是false。public static mut prop toThrowOnRollbacking: Bool
        MOCKDB.toThrowOnRollbackingSavePoint('savepoint', false)//指定回滚到指定的savepoint时是否抛出异常。
        MOCKDB.toThrowOnRollbackingSavePoint('savepoint')//返回回滚到指定的savepoint时是否抛出异常，如果返回true则回滚到指定savepoint时会抛出异常，默认返回false。public static func toThrowOnRollbackingSavePoint(savepoint: String): Bool
        MOCKDB.toThrowOnSavingSavePoint('savepoint', false)//指定保存指定的savepoint时是否抛出异常
        MOCKDB.toThrowOnSavingSavePoint('savepoint')//返回保存指定savepoint时是否抛出异常，如果返回true则保存指定savepoint时会抛出异常，默认返回false。public static func toThrowOnSavingSavePoint(savepoint: String): Bool
    }
}()
```
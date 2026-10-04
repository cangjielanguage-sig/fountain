/*
Copyright (c) 2025 WuJingrun（吴京润）

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/
package fountain::f_mockdb

public class MockStatement <: Statement {
    private var closed_ = false
    private let args = ArrayList<Any>()
    MockStatement(private let sql: String){}
    public prop parameterColumnInfos: Array<ColumnInfo> {
        get() {
            []
        }
    }
    public func query(params: Array<SqlDbType>): QueryResult {
        throw MockDbException('not supported')
    }
    public func setOption(key: String, value: String): Unit {
        MOCKDB.log('Statement option: (key: ${key}, value: ${value})')
    }
    public func update(params: Array<SqlDbType>): UpdateResult {
        throw MockDbException('not supported')
    }
    public func set<T>(index: Int, value: T): Unit {
        if(index < 0){
            //按 std 契约：参数索引越界抛 SqlException
            throw SqlException('parameter index ${index} is negative')
        }
        for(_ in args.size ..= index) {
            args.add(None<Any>)
        }
        args[index] = value
    }
    public func setNull(index: Int): Unit {
        if(index < 0){
            //按 std 契约：参数索引越界抛 SqlException
            throw SqlException('parameter index ${index} is negative')
        }
        for(_ in args.size ..= index) {
            args.add(None<Any>)
        }
        if(index < args.size) {
            args[index] = None<Any>
        }
    }
    public func update(): UpdateResult {
        //每次执行前清掉上一次的结果，保证本次只看到本次夹具写入的行与列信息
        MOCKDB.clearQueryResult()
        //声明抛异常时直接失败：不执行夹具、不产生结果（与真驱动一致）
        if(MOCKDB.toThrowOnExecuting){
            throw MockDbException('failed to execute sql: ${sql}')
        }
        try {
            MOCKDB.execution(sql, args)
        } finally {
            //本次执行结束即清空参数槽：语句复用时不再带上一次绑定的参数
            args.clear()
        }
        //取快照：本次执行写入的 lastInsertId / rowCount 就是本对象的值
        MockUpdateResult(MOCKDB.lastInsertId, MOCKDB.rowCount)
    }
    public func query(): QueryResult {
        //每次执行前清掉上一次的结果，保证本次只看到本次夹具写入的行与列信息
        MOCKDB.clearQueryResult()
        //声明抛异常时直接失败：不执行夹具、不产生结果（与真驱动一致）
        if(MOCKDB.toThrowOnExecuting){
            throw MockDbException('failed to execute sql: ${sql}')
        }
        try {
            MOCKDB.execution(sql, args)
        } finally {
            //本次执行结束即清空参数槽：语句复用时不再带上一次绑定的参数
            args.clear()
        }
        MockQueryResult()
    }
    public func isClosed(): Bool {
        closed_
    }
    public func close(): Unit {
        closed_ = true
    }
}
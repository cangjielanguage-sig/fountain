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

public class MockQueryResult <: QueryResult {
    private var closed_ = false
    private var rowIndex = -1
    //构造时快照本次执行的结果：之后的执行（或 clearQueryResult）不再改变本结果集
    private let rowData: Array<Array<Any>> = MOCKDB.getQueryResultRows().toArray()
    private let columnInfos_: Array<ColumnInfo> = MOCKDB.queryResultColumnInfos
    public prop columnInfos: Array<ColumnInfo> {
        get() {
            if(columnInfos_.isEmpty()){
                throw MockDbException('column infos from QueryResult must not be empty, to invoke MOCKDB.addQueryResultColumnInfo(name: "...", nullable: "...", typeName: "...") to add ColumnInfo for QueryResult.')
            }
            columnInfos_
        }
    }
    public func next(values: Array<SqlDbType>): Bool {
        throw MockDbException('not supported')
    }
    public func next(): Bool {
        rowIndex++
        rowIndex < rowData.size
    }
    public func get<T>(index: Int): T {
        getOrNull<T>(index).getOrThrow()
    }
    public func getOrNull<T>(index: Int): ?T {
        //按 std.database.sql 契约区分三种情况：行未就绪/列越界抛 SqlException，只有真正的 SQL NULL 才返回 None
        if(rowIndex < 0 || rowIndex >= rowData.size){
            throw SqlException('row data is not ready, invoke next() before reading column ${index}')
        }
        let row = rowData[rowIndex]
        if(index < 0 || index >= row.size){
            throw SqlException('column index ${index} is out of range, the current row has ${row.size} columns')
        }
        let value = row[index]
        match(value){
            case x: T => x
            case x: Option<Any> where x.isNone() => None
            case _ => throw SqlException('value of column ${index} is ${TypeInfo.of(value)}, which does not match ${TypeInfo.of<T>()}')
        }
    }
    public func isClosed(): Bool {
        closed_
    }
    public func close(): Unit {
        closed_ = true
    }
}
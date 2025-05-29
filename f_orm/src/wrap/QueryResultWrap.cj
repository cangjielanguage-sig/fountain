/*
   Copyright (c) [2022] [WuJingrun（吴京润）]
   fountain is licensed under Mulan PSL v2.
   You can use this software according to the terms and conditions of the Mulan PSL v2.
   You may obtain a copy of Mulan PSL v2 at:
           http://license.coscl.org.cn/MulanPSL2
   THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
   See the Mulan PSL v2 for more details.
 */

package f_orm.wrap

import std.database.sql.*
import f_base.*

public class QueryResultWrap <: QueryResult {
    private let columnInfoMap = HashMap<String, Int64>()
    private let list = ArrayList<Any>()
    public QueryResultWrap(private let driverName: String, private let result: QueryResult) {
        for(i in 0 .. columnInfos.size){
            columnInfoMap[columnInfos[i].name] = i
        }
    }
    public func next(): Bool {
        result.next()
    }

    public prop columnInfos: Array<ColumnInfo> {
        get() {
            result.columnInfos
        }
    }
    public func get<T>(index: Int64): T {
        getOrNull<T>(index).getOrThrow()
    }
    public func getOrNull<T>(index: Int64): ?T {
        if(index >= list.size){
            for(i in list.size ..= index){
                list.add(result.getOrNull<T>(i))
            }
        }
        (list[index] as ?T).getOrThrow()
    }
    public func get<T>(columnName: String): T{
        get<T>(columnInfoMap[columnName])
    }
    public func getOrNull<T>(columnName: String): ?T {
        getOrNull<T>(columnInfoMap[columnName])
    }
    public func next(values: Array<SqlDbType>): Bool {
        throw ORMException('this func is deprecated')
    }
    public func toMap(): HashMap<String, Any> {
        let map = HashMap<String, Any>()
        for((column, index) in columnInfoMap){
            map[column] = get(index)
        }
        map
    }
    public func isClosed(): Bool {
        result.isClosed()
    }
    public func close(): Unit {
        result.close()
    }
}

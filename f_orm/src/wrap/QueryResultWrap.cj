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
package f_orm.wrap

import std.database.sql.*
import f_base.*

public class QueryResultWrap <: QueryResult {
    private let columnInfoMap = HashMap<String, Int64>()
    private let list = ArrayList<Any>()
    public QueryResultWrap(private let driverName: String, private let result: QueryResult) {
        for (i in 0..columnInfos.size) {
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
        if (index >= list.size) {
            for (i in list.size..=index) {
                list.add(result.getOrNull<T>(i))
            }
        }
        (list[index] as ?T).getOrThrow()
    }
    public func get<T>(columnName: String): T {
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
        for ((column, index) in columnInfoMap) {
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

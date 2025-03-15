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

public class QueryResultWrap <: Iterator<Row> & QueryResult {
    private var row: Array<SqlDbType> = []
    private let columnInfoMap: Map<String, Int64> = HashMap<String, Int64>()
    public QueryResultWrap(private let driverName: String, private let result: QueryResult) {
        let columnInfos = result.columnInfos
        row = Array<SqlDbType>(columnInfos.size) {
            i =>
            let info = columnInfos[i]
            this.columnInfoMap[info.name] = i
            let typeName = info.typeName
            SqlDataCreators.generate(driverName, typeName)
        }
    }
    public func next(): ?Row {
        let row = this.row
        if (result.next(row)) {
            RowWrap(driverName, columnInfoMap, row)
        } else {
            None
        }
    }

    public prop columnInfos: Array<ColumnInfo> {
        get() {
            result.columnInfos
        }
    }
    public func next(values: Array<SqlDbType>): Bool {
        result.next(values)
    }
    public func isClosed(): Bool {
        result.isClosed()
    }
    public func close(): Unit {
        result.close()
    }
}

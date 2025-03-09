/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_orm

import std.random.Random

public class QueryResultTest <: QueryResult {
    public func isClosed(): Bool {
        false
    }
    public func close(): Unit {
    }
    public prop columnInfos: Array<ColumnInfo> {
        get() {
            [
                ColumnInfoTest("id", "SqlBigInt"),
                ColumnInfoTest("username", "SqlVarchar"),
                ColumnInfoTest("logged", "SqlBool"),
                ColumnInfoTest("register_time", "SqlTimestamp")
            ]
        }
    }
    private var i = 0
    private var s = String.empty
    private var b = false
    public func next(values: Array<SqlDbType>): Bool {
        if (i > 2) {
            return false
        }
        var j = 0
        while (j < values.size) {
            let value = values[j]
            match (j) {
                case 0 =>
                    let sqlval = (value as SqlBigInt).getOrThrow()
                    i++
                    sqlval.value = i
                case 1 =>
                    s += "s"
                    let sqlval = (value as SqlVarchar).getOrThrow()
                    sqlval.value = s
                case 2 =>
                    b = !b
                    let sqlval = (value as SqlBool).getOrThrow()
                    sqlval.value = b
                case 3 =>
                    let sqlval = (value as SqlTimestamp).getOrThrow()
                    sqlval.value = DateTime.now()
                case _ => throw Exception("too many columns")
            }
            j++
        }
        true
    }
}

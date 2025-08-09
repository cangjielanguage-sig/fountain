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
package f_orm

import std.random.Random

public class QueryResultTest <: QueryResultWrap {
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

/*
Copyright (c) 2026 WuJingrun（吴京润）

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
package fountain::fdbm.execute

import std.database.sql.*
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.DataReal
import fountain::f_dbd.common.{ColumnInfoImpl, DbdErrorCode}
import fountain::fdbm.exception.FdbmException

/** G28：`next()` 推进失败后必须复位当前行，不能让 `cell()` 读到上一行。 */
@Test
public class CursorRecoveryTest {

    @TestCase
    public func failedAdvanceClearsCurrentRow(): Unit {
        let cursor = QueryCursor([], [ColumnInfoImpl('id', 'Int64', 20, 0, false, 21)],
            memory: Some<QueryResult>(FlakyQueryResult()))
        try {
            @Assert(cursor.next(), true)

            var failed = false
            try {
                cursor.next()
            } catch (_: Exception) {
                failed = true
            }
            @Assert(failed, true)
            // 推进失败后旧行必须失效；修复前这里会返回上一行的 1
            @Assert(codeOf { cursor.cell(0, 0) }, DbdErrorCode.CURSOR_STATE)
        } finally {
            cursor.close()
        }
    }

    private func codeOf<T>(body: () -> T): DbdErrorCode {
        try {
            body()
        } catch (e: FdbmException) {
            return e.code
        } catch (_: Exception) {
            return DbdErrorCode.INTERNAL
        }
        DbdErrorCode.INTERNAL
    }
}

/** 第一行可读，第二次 `next()` 抛异常（模拟物理驱动中途失败）。 */
class FlakyQueryResult <: QueryResult {
    private var calls: Int64 = 0

    public prop columnInfos: Array<ColumnInfo> {
        get() {
            [ColumnInfoImpl('id', 'Int64', 20, 0, false, 21)]
        }
    }

    public func next(values: Array<SqlDbType>): Bool {
        throw Exception('not supported')
    }

    public func next(): Bool {
        calls += 1
        if (calls == 1) {
            return true
        }
        throw Exception('injected advance failure')
    }

    public func get<T>(index: Int64): T {
        getOrNull<T>(index).getOrThrow()
    }

    public func getOrNull<T>(index: Int64): ?T {
        let value: Any = DataReal(1)
        match (value) {
            case x: T => Some(x)
            case _ => None<T>
        }
    }

    public func isClosed(): Bool {
        false
    }

    public func close(): Unit {}
}

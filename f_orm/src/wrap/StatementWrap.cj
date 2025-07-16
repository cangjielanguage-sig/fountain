/*
    Copyright (c) 2022 WuJingrun（吴京润）
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_orm.wrap

public class StatementWrap <: Statement {
    public StatementWrap(let driverName: String, private let statement: Statement) {}

    public prop parameterColumnInfos: Array<ColumnInfo> {
        get() {
            statement.parameterColumnInfos
        }
    }
    public func setOption(key: String, value: String): Unit {
        statement.setOption(key, value)
    }
    public func set<T>(index: Int64, value: T): Unit {
        statement.set<T>(index, value)
    }
    public func setNull(index: Int64): Unit {
        statement.setNull(index)
    }
    public func update(params: Array<SqlDbType>): UpdateResult {
        throw ORMException('current access is deprecated')
    }
    public func query(params: Array<SqlDbType>): QueryResultWrap {
        throw ORMException('current access is deprecated')
    }
    public func update(): UpdateResult {
        statement.update()
    }
    public func query(): QueryResultWrap {
        QueryResultWrap(driverName, statement.query())
    }
    public func isClosed(): Bool {
        statement.isClosed()
    }
    public func close(): Unit {
        statement.close()
    }
}

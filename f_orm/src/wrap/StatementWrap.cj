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
package fountain::f_orm.wrap

public class StatementWrap <: Statement {
    private let indexStartsWith: Int64
    public StatementWrap(let driverName: String, private let statement: Statement) {
        indexStartsWith = if(ORMConfig.getIndexStartsWithZero(driverName: driverName)){
            0
        }else{
            1
        }
    }

    public prop parameterColumnInfos: Array<ColumnInfo> {
        get() {
            statement.parameterColumnInfos
        }
    }
    public func setOption(key: String, value: String): Unit {
        statement.setOption(key, value)
    }
    public func set<T>(index: Int64, value: T): Unit {
        statement.set<T>(index + indexStartsWith, value)
    }
    public func setNull(index: Int64): Unit {
        statement.setNull(index + indexStartsWith)
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

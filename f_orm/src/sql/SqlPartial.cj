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
package f_orm.sql

public interface SqlPartial <: RootDAO {
    func INTO<T>(): IntoClause<T> where T <: QueryMappersInit<T>
    func UPDATE<T>(): UpdateClause<T> where T <: QueryMappersInit<T>
    func FROM<T>(): FromClause<T> where T <: QueryMappersInit<T>
    func page<R>(sql: String, size: Int64, page!: Int64): Pagination<R> where R <: QueryMappersInit<R> & DataFields<R>
    func singlePage<R>(sql: String, size: Int64, page!: Int64): Pagination<R> where R <: DataFields<R>
}
extend SqlExecutor <: SqlPartial {
    public func INTO<T>(): IntoClause<T> where T <: QueryMappersInit<T> {
        IntoClause<T>(this)
    }
    public func UPDATE<T>(): UpdateClause<T> where T <: QueryMappersInit<T> {
        UpdateClause<T>(this)
    }
    public func FROM<T>(): FromClause<T> where T <: QueryMappersInit<T> {
        FromClause<T>(this)
    }
    private func page<R>(partial: String, size: Int64, page: Int64, callee: (SqlExecutor) -> ArrayList<R>): Pagination<R> where R <: DataFields<R> {
        let partial_ = partial.trimAsciiStart()
        if(partial_[0 .. 6].toAsciiLower() == 'select' && partial_[7] <= b' '){
            throw ORMException('${partial} is not a select.')
        }
        let countSql = 'select count(*) from (${partial}) as __tmp___'//如果sql中包含order by 这样也可以执行
        let count = executor.setSql(countSql, clearArgsAfterExec: false).first<Int64>() ?? 0
        Pagination<R>(page: page, rows: count, size: size){size: Int64, offset: Int64 =>
            let (one, two, psql) = SqlDialectMediator.instance.getDialect(this.driverName).limit(size, offset)
            executor.add(one).add(two).setSql('select * from (${partial}) as __tmp___ ${psql}') |> callee
        }
    }
    public func page<R>(sql: String, size: Int64, page!: Int64 = 1): Pagination<R> where R <: QueryMappersInit<R> & DataFields<R> {
        page<R>(sql, size, page){exe => exe.list<R>()}
    }
    public func singlePage<R>(sql: String, size: Int64, page!: Int64 = 1): Pagination<R> where R <: DataFields<R> {
        page<R>(sql, size, page){exe => exe.singleList<R>()}
    }
}
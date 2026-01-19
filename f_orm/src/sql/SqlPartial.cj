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
    func INTO<T>(ignoreColumns!: Array<String>): IntoClause<T> where T <: QueryMappersInit<T>
    func INTO<T>(values: T, ignoreColumns!: Array<String>): Int64 where T <: QueryMappersInit<T> & ObjectData<T>
    func UPDATE<T>(): UpdateClause<T> where T <: QueryMappersInit<T>
    /**
     * map的key可以是列名或T的公共实例成员名，values必须包含主键键值对
     */
    func UPDATE<T>(values: Map<String, Any>): Int64 where T <: QueryMappersInit<T>
    /**
     * map的key可以是列名或T的公共实例成员名
     */
    func UPDATE<T, ID>(values: Map<String, Any>, id: ID): Int64 where T <: QueryMappersInit<T>
    /**
     * ignoreColumns/includingColumns可以指定values的公共成员或对应的列名，两个参数要么都不指定，要么只指定一个，都指定会抛异常
     */
    func UPDATE<T>(values: T, ignoreColumns!: Array<String>, includingColumns!: Array<String>): Int64 where T <: QueryMappersInit<T> & ObjectData<T>
    func FROM<T>(): FromClause<T> where T <: QueryMappersInit<T>
    func page<R>(sql: String, size: Int64, page!: Int64): Pagination<R> where R <: QueryMappersInit<R> & DataFields<R>
    func singlePage<R>(sql: String, size: Int64, page!: Int64): Pagination<R> where R <: DataFields<R>
    func singleFirst<T>(sql: String): ?T{
        singleFirst<T>(sql, 0)
    }
    func singleFirst<T>(sql: String, column: Int64): ?T
    func singleFirst<T>(sql: String, column: String): ?T
    func first<T>(sql: String, mappers: QueryMappers<T>): Option<T> 
    func first<T>(sql: String): Option<T> where T <: QueryMappersInit<T> 
    func firstToMap(sql: String): Map<String, Any> 
}
extend SqlExecutor <: SqlPartial {
    public func INTO<T>(ignoreColumns!: Array<String> = []): IntoClause<T> where T <: QueryMappersInit<T> {
        IntoClause<T>(this, ignoreColumns)
    }
    public func INTO<T>(values: T, ignoreColumns!: Array<String>): Int64 where T <: QueryMappersInit<T> & ObjectData<T> {
        INTO<T>(ignoreColumns: ignoreColumns).VALUES<T>(values).execute()
    }
    public func UPDATE<T>(): UpdateClause<T> where T <: QueryMappersInit<T> {
        UpdateClause<T>(this)
    }
    public func UPDATE<T>(values: Map<String, Any>): Int64 where T <: QueryMappersInit<T> {
        var idField = ''
        var idColumn = ''
        let sql = StringGenerator().append('UPDATE ').append(T.tableName()).append(' SET ')
        let sqlsize = sql.size
        for(m in T.queryMappers().mappers){
            let column = m.columnName
            let field = m.fieldName
            if(m.isId){
                idField = field
                idColumn = column
            }
            if(let Some(v) <- values.get(field)){
                sql.append(column).append('=').append(arg(v))
            }else if(let Some(v) <- values.get(column)){
                sql.append(column).append('=').append(arg(v))
            }
        }
        if(idColumn.isEmpty()){
            throw NoIdException(TypeInfo.of<T>().qualifiedName)
        }
        sql.append(' WHERE ').append(idColumn).append('=').append(if(let Some(v) <- values.get(idField)){
            arg(v)
        }else{
            arg(values[idColumn])
        })
        executor.setSql(sql.toString()).update
    }
    public func UPDATE<T, ID>(values: Map<String, Any>, id: ID): Int64 where T <: QueryMappersInit<T> {
        var idField = ''
        var idColumn = ''
        let sql = StringGenerator().append('UPDATE ').append(T.tableName()).append(' SET ')
        let sqlsize = sql.size
        for(m in T.queryMappers().mappers){
            let column = m.columnName
            let field = m.fieldName
            if(m.isId){
                idField = field
                idColumn = column
            }
            if(let Some(v) <- values.get(field)){
                sql.append(column).append('=').append(arg(v))
            }else if(let Some(v) <- values.get(column)){
                sql.append(column).append('=').append(arg(v))
            }
        }
        if(idColumn.isEmpty()){
            throw NoIdException(TypeInfo.of<T>().qualifiedName)
        }
        sql.append(' WHERE ').append(idColumn).append('=').append(arg(id))
        executor.setSql(sql.toString()).update
    }
    public func UPDATE<T>(values: T, ignoreColumns!: Array<String> = [], includingColumns!: Array<String> = []): Int64 where T <: QueryMappersInit<T> & ObjectData<T> {
        var idField = ''
        var idColumn = ''
        let data = DataObject<T>(values)
        let includings = HashSet<String>(includingColumns)
        let ignored = HashSet<String>(ignoreColumns)
        let sql = StringGenerator().append('UPDATE ').append(T.tableName()).append(' SET ')
        let sqlsize = sql.size
        for(m in T.queryMappers().mappers){
            let column = m.columnName
            let field = m.fieldName
            if(m.isId){
                idField = field
                idColumn = column
            }
            if((includings.isEmpty() && ignored.isEmpty()) || 
               (includings.isEmpty() && !(ignored.contains(column) || ignored.contains(field))) || 
               (ignored.isEmpty() && (includings.contains(column) || includings.contains(field)))){
                if(sql.size > sqlsize){
                    sql.append(', ')
                }
                sql.append(column).append('=').append(arg(data[field]))
            }else if (includings.size > 0 && ignored.size > 0){
                throw IllegalArgumentException('ignoreColumns and includingColumns must not be specified both.')
            }
        }
        if(idColumn.isEmpty()){
            throw NoIdException(TypeInfo.of<T>().qualifiedName)
        }
        sql.append(' WHERE ').append(idColumn).append('=').append(arg(data[idField]))
        executor.setSql(sql.toString()).update
    }
    public func FROM<T>(): FromClause<T> where T <: QueryMappersInit<T> {
        FromClause<T>(this)
    }
    private func selectPage<R>(partial: String, size: Int64, page: Int64, callee: (SqlExecutor) -> ArrayList<R>): Pagination<R> where R <: DataFields<R> {
        let partial_ = partial.trimAsciiStart()
        if(partial_[0 .. 6].toAsciiLower() == 'select' && partial_[7] <= b' '){
            throw ORMException('${partial} is not a select.')
        }
        let countSql = 'select count(*) from (${partial}) as __tmp___'//如果sql中包含order by 这样也可以执行
        let count = executor.setSql(countSql, clearArgsAfterExec: false).first<Int64>() ?? 0
        if(count == 0){
            executor.clearSql()
        }
        Pagination<R>(page: page, rows: count, size: size){size: Int64, offset: Int64 =>
            let (one, two, psql) = SqlDialectMediator.instance.getDialect(this.driverName).limit(size, offset)
            executor.add(one).add(two).setSql('select * from (${partial}) as __tmp___ ${psql}', clearArgsAfterExec: true) |> callee
        }
    }
    public func page<R>(sql: String, size: Int64, page!: Int64 = 1): Pagination<R> where R <: QueryMappersInit<R> & DataFields<R> {
        selectPage<R>(sql, size, page){exe => exe.list<R>()}
    }
    public func singlePage<R>(sql: String, size: Int64, page!: Int64 = 1): Pagination<R> where R <: DataFields<R> {
        selectPage<R>(sql, size, page){exe => exe.singleList<R>()}
    }
    private func limit(size: Int64, offset!: Int64 = 0): String {
        let (one, two, sql) = SqlDialectMediator.instance.getDialect(executor.driverName).limit(size, offset)
        this.executor.add(one).add(two)
        sql
    }
    private func sqlWithLimit(sql: String) {
        executor.setSql('${sql} ${limit(1)}')
    }
    public func singleFirst<T>(sql: String, column: Int64): ?T {
        sqlWithLimit(sql).singleFirst<T>(column)
    }
    public func singleFirst<T>(sql: String, column: String): ?T {
        sqlWithLimit(sql).singleFirst<T>(column)
    }
    public func first<T>(sql: String, mappers: QueryMappers<T>): Option<T> {
        sqlWithLimit(sql).first<T>(mappers)
    }
    public func first<T>(sql: String): Option<T> where T <: QueryMappersInit<T> {
        sqlWithLimit(sql).first<T>()
    }
    public func firstToMap(sql: String): Map<String, Any> {
        sqlWithLimit(sql).firstToMap()
    }
}
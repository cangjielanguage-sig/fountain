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
package fountain::f_orm.base

public interface SqlPartial <: RootDAO {
    func INTO<T>(ignoreColumns!: Array<String>): IntoClause<T> where T <: QueryMappersInit<T>
    func INTO<T>(values: T, ignoreColumns!: Array<String>): Int64 where T <: QueryMappersInit<T> & ObjectData<T>
    func INTO<T>(values: T): Int64 where T <: QueryMappersInit<T> & ObjectData<T> {
        INTO<T>(values, ignoreColumns: [])
    }
    func INSERT_INTO<T>(ignoreColumns!: Array<Column>, includingColumns!: Array<Column>): IntoClause<T> where T <: QueryMappersInit<T>
    func INSERT_INTO<T>(values: T, ignoreColumns!: Array<Column>): Int64 where T <: QueryMappersInit<T> & ObjectData<T>
    func INSERT_INTO<T>(values: T): Int64 where T <: QueryMappersInit<T> & ObjectData<T> {
        return INSERT_INTO<T>(values, ignoreColumns: Array<Column>())
    }
    func UPDATE<T>(AS!: String): UpdateClause<T> where T <: QueryMappersInit<T>
    func UPDATE<T>(): UpdateClause<T> where T <: QueryMappersInit<T>
    /**
     * map的key可以是列名或T的公共实例成员名，values必须包含主键键值对
     */
    func UPDATE<T>(values: Map<String, Any>): Int64 where T <: QueryMappersInit<T>
    /**
     * map的key可以是列名或T的公共实例成员名
     */
    func UPDATE<T, ID>(values: Map<String, Any>, id: ID): Int64 where T <: QueryMappersInit<T>
    func UPDATE<T>(values: T, ignoredColumns!: HashSet<String>, includingColumns!: HashSet<String>, dirty!: Bool): Int64 where T <: QueryMappersInit<T> & ObjectData<T>
    /**
     * ignoredColumns/includingColumns可以指定values的公共成员或对应的列名，两个参数要么都不指定，要么只指定一个，都指定会抛异常
     */
    func UPDATE<T>(values: T, ignoredColumns!: Array<String>, includingColumns!: Array<String>, dirty!: Bool): Int64 where T <: QueryMappersInit<T> & ObjectData<T>
    func UPDATE<T>(values: T): Int64 where T <: QueryMappersInit<T> & ObjectData<T> {
        let empty = Array<String>()
        UPDATE<T>(values, ignoredColumns: empty, includingColumns: empty, dirty: false)
    }
    func UPDATE<T>(values: T, ignoredColumns!: HashSet<String>, includingColumns!: HashSet<String>): Int64 where T <: QueryMappersInit<T> & ObjectData<T> {
        UPDATE<T>(values, ignoredColumns: ignoredColumns, includingColumns: includingColumns, dirty: false)
    }
    func UPDATE<T>(values: T, ignoredColumns!: Array<String>, includingColumns!: Array<String>): Int64 where T <: QueryMappersInit<T> & ObjectData<T> {
        UPDATE<T>(values, ignoredColumns: ignoredColumns, includingColumns: includingColumns, dirty: false)
    }
    func UPDATE<T>(values: T, dirty!: Bool): Int64 where T <: QueryMappersInit<T> & ObjectData<T> {
        let empty = Array<String>()
        UPDATE<T>(values, ignoredColumns: empty, includingColumns: empty, dirty: dirty)
    }
    func UPDATE<T>(values: T, ignoredColumns!: Array<Column>, includingColumns!: Array<Column>, dirty!: Bool): Int64 where T <: QueryMappersInit<T> & ObjectData<T> {
        UPDATE<T>(values, ignoredColumns: Array<String>(ignoredColumns.size){i => ignoredColumns[i].name}, includingColumns: Array<String>(includingColumns.size){i => includingColumns[i].name}, dirty: dirty)
    }
    func UPDATE<T>(values: T, ignoredColumns!: Array<Column>, includingColumns!: Array<Column>): Int64 where T <: QueryMappersInit<T> & ObjectData<T> {
        UPDATE<T>(values, ignoredColumns: Array<String>(ignoredColumns.size){i => ignoredColumns[i].name}, includingColumns: Array<String>(includingColumns.size){i => includingColumns[i].name}, dirty: false)
    }
    func FROM<T>(AS!: String): FromClause<T> where T <: QueryMappersInit<T>
    func FROM<T>(): FromClause<T> where T <: QueryMappersInit<T>
    func page<R>(sql: String, size: Int64, page!: Int64): Pagination<R> where R <: QueryMappersInit<R> & DataFields<R>
    func singlePage<R>(sql: String, size: Int64, page!: Int64): Pagination<R> where R <: DataFields<R> {
        singlePage<R>(sql, 0, size, page: page)
    }
    func singlePage<R>(sql: String, column: Int64, size: Int64, page!: Int64): Pagination<R> where R <: DataFields<R>
    func singleFirst<T>(sql: String): ?T{
        singleFirst<T>(sql, 0)
    }
    func singleFirst<T>(sql: String, column: Int64): ?T
    func singleFirst<T>(sql: String, column: String): ?T
    func first<T>(sql: String, mappers: QueryMappers<T>): Option<T> 
    func first<T>(sql: String): Option<T> where T <: QueryMappersInit<T> 
    func firstToMap(sql: String): Map<String, Any> 
}
private let sqlPartialLog = LoggerFactory.getLogger('fountain::f_orm.sqlpartial')
extend SqlExecutor <: SqlPartial {
    private prop dialect: SqlDialect {
        get(){
            SqlDialectMediator.instance.getDialect(this.driverName)
        }
    }
    func involve(identifier: String): String {
        dialect.involvedIdentifier(identifier)
    }
    private func involveTable<T>(): String where T <: QueryMappersInit<T> {
        involve(T.tableName())
    }
    public func INTO<T>(ignoreColumns!: Array<String> = []): IntoClause<T> where T <: QueryMappersInit<T> {
        IntoClause<T>(this, ignoreColumns)
    }
    public func INTO<T>(values: T, ignoreColumns!: Array<String> = []): Int64 where T <: QueryMappersInit<T> & ObjectData<T> {
        INTO<T>(ignoreColumns: ignoreColumns).VALUES<T>(values).execute()
    }
    public func INSERT_INTO<T>(ignoreColumns!: Array<Column>, includingColumns!: Array<Column>): IntoClause<T> where T <: QueryMappersInit<T> {
        IntoClause<T>(this, ignoreColumns, includingColumns)
    }
    public func INSERT_INTO<T>(values: T, ignoreColumns!: Array<Column>): Int64 where T <: QueryMappersInit<T> & ObjectData<T> {
        INSERT_INTO<T>(ignoreColumns: ignoreColumns, includingColumns: []).VALUES<T>(values).execute()
    }
    public func UPDATE<T>(AS!: String): UpdateClause<T> where T <: QueryMappersInit<T> {
        UpdateClause<T>(this, AS)
    }
    public func UPDATE<T>(): UpdateClause<T> where T <: QueryMappersInit<T> {
        UPDATE<T>(AS: '')
    }
    public func UPDATE<T>(values: Map<Column, Any>): Int64 where T <: QueryMappersInit<T> {
        let values2 = HashMap<String, Any>()
        for((k, v) in values){
            values2[k.name] = v
        }
        UPDATE<T>(values2)
    }
    public func UPDATE<T>(values: Map<String, Any>): Int64 where T <: QueryMappersInit<T> {
        if(values.isEmpty()){
            throw SqlArgException('no column to udpate')
        }
        var idField = ''
        var idColumn = ''
        let sql = StringGenerator().append('UPDATE ').append(involveTable<T>()).append(' SET ')
        let sqlsize = sql.size
        for(m in T.queryMappers().mappers){
            let column = m.columnName
            let field = m.fieldName
            if(m.isId){
                idField = field
                idColumn = column
                continue
            }
            if(sql.size > sqlsize){
                sql.append(', ')
            }
            if(let Some(v) <- values.get(field)){
                sql.append(involve(column)).append('=').append(arg(v))
            }else if(let Some(v) <- values.get(column)){
                sql.append(involve(column)).append('=').append(arg(v))
            }
        }
        if(idColumn.isEmpty()){
            throw NoIdException(TypeInfo.of<T>().qualifiedName)
        }else if (sql.size == sqlsize){
            throw SqlArgException('no column to update')
        }
        sql.append(' WHERE ').append(involve(idColumn)).append('=').append(if(let Some(v) <- values.get(idField)){
            arg(v)
        }else{
            arg(values[idColumn])
        })
        executor.setSql(sql.toString()).update
    }
    public func UPDATE<T, ID>(values: Map<Column, Any>, id: ID): Int64 where T <: QueryMappersInit<T> {
        let values2 = HashMap<String, Any>()
        for((k, v) in values){
            values2[k.name] = v
        }
        UPDATE<T, ID>(values2, id)
    }
    public func UPDATE<T, ID>(values: Map<String, Any>, id: ID): Int64 where T <: QueryMappersInit<T> {
        if(values.isEmpty()){
            throw SqlArgException('no column to udpate')
        }
        let dialect = this.dialect
        var idColumn = ''
        let sql = StringGenerator().append('UPDATE ').append(involveTable<T>()).append(' SET ')
        let sqlsize = sql.size
        for(m in T.queryMappers().mappers){
            let column = m.columnName
            let field = m.fieldName
            if(m.isId){
                idColumn = column
                continue
            }
            if(sql.size > sqlsize){
                sql.append(', ')
            }
            if(let Some(v) <- values.get(field)){
                sql.append(involve(column)).append('=').append(arg(v))
            }else if(let Some(v) <- values.get(column)){
                sql.append(involve(column)).append('=').append(arg(v))
            }
        }
        if(idColumn.isEmpty()){
            throw NoIdException(TypeInfo.of<T>().qualifiedName)
        }else if (sql.size == sqlsize){
            throw SqlArgException('no column to update')
        }
        sql.append(' WHERE ').append(involve(idColumn)).append('=').append(arg(id))
        executor.setSql(sql.toString()).update
    }
    public func UPDATE<T>(values: T, ignoredColumns!: HashSet<String>, includingColumns!: HashSet<String>, dirty!: Bool): Int64 where T <: QueryMappersInit<T> & ObjectData<T> {
        sqlPartialLog.debug{'SqlPartial.UPDATE<${TypeInfo.of<T>()}> ${involveTable<T>()} ignoredColumns: ${ignoredColumns} includingColumns: ${includingColumns} dirty: ${dirty}'}
        if ((ignoredColumns.size > 0 && includingColumns.size > 0) || 
            (ignoredColumns.size > 0 && dirty) || 
            (includingColumns.size > 0 && dirty)){
            throw IllegalArgumentException('ignoreColumns includingColumns and true value for dirty must not be specified at the same time for update.')
        } else if (dirty && let dirtyFields <- DirtyTag.getDirtyFields<T>()) {
            if(dirtyFields.isEmpty()){
                return 0
            }
            try{
                return UPDATE<T>(values, includingColumns: dirtyFields, ignoredColumns: HashSet<String>())
            }finally{
                dirtyFields.clear()
            }
        }
        var idField = ''
        var idColumn = ''
        let data = DataObject<T>(values)
        let sql = StringGenerator().append('UPDATE ').append(involveTable<T>()).append(' SET ')
        let sqlsize = sql.size
        for(m in T.queryMappers().mappers){
            let column = m.columnName
            let field = m.fieldName
            if(m.isId){
                idField = field
                idColumn = column
            }else if((includingColumns.isEmpty() && ignoredColumns.isEmpty()) || 
               (includingColumns.isEmpty() && !(ignoredColumns.contains(column) || ignoredColumns.contains(field))) || 
               (ignoredColumns.isEmpty() && (includingColumns.contains(column) || includingColumns.contains(field)))){
                if(sql.size > sqlsize){
                    sql.append(', ')
                }
                sql.append(involve(column)).append('=').append(arg(data[field]))
            }
        }
        if(sql.size == sqlsize){
            return 0
        }
        if(idColumn.isEmpty()){
            throw NoIdException(TypeInfo.of<T>().qualifiedName)
        }else if (sql.size == sqlsize){
            throw SqlArgException('no column to update')
        }
        sql.append(' WHERE ').append(involve(idColumn)).append('=').append(arg(data[idField]))
        executor.setSql(sql.toString()).update
    }
    public func UPDATE<T>(values: T, ignoredColumns!: Array<String>, includingColumns!: Array<String>, dirty!: Bool): Int64 where T <: QueryMappersInit<T> & ObjectData<T> {
        if (ignoredColumns.size > 0 && includingColumns.size > 0){
            throw IllegalArgumentException('ignoredColumns and includingColumns must not be specified both.')
        }else if(includingColumns.size > 0){
            UPDATE<T>(values, includingColumns: HashSet<String>(includingColumns), ignoredColumns: HashSet<String>(), dirty: dirty)
        }else if(ignoredColumns.size > 0){
            UPDATE<T>(values, ignoredColumns: HashSet<String>(ignoredColumns), includingColumns: HashSet<String>(), dirty: dirty)
        }else{
            let empty = HashSet<String>()
            UPDATE<T>(values, ignoredColumns: empty, includingColumns: empty, dirty: dirty)
        }
    }
    public func FROM<T>(AS!: String): FromClause<T> where T <: QueryMappersInit<T> {
        FromClause<T>(this, AS)
    }
    public func FROM<T>(): FromClause<T> where T <: QueryMappersInit<T> {
        FROM<T>(AS: '')
    }
    private func selectPage<R>(partial: String, size: Int64, page: Int64, callee: (SqlExecutor) -> ArrayList<R>): Pagination<R> where R <: DataFields<R> {
        if (let partial_ <- partial.trimAsciiStart() && 
            partial_.size >= 8 && partial_[0 .. 6].equalsIgnoreAsciiCase('select') && 
            let b <- partial_[6] && (b == b' ' || b == b'\t' || b == b'\r' || b == b'\n')){
        }else{
            throw ORMException('${partial} is not a select.')
        }
        try{
            let countSql = 'select count(*) from (${partial}) as __tmp___'//如果sql中包含order by 这样也可以执行
            let count = executor.setSql(countSql, clearArgsAfterExec: false).first<Int64>() ?? 0
            Pagination<R>(page: page, rows: count, size: size){size: Int64, offset: Int64 =>
                let (one, two, psql) = dialect.limit(size, offset)
                executor.add(one).add(two).setSql('select * from (${partial}) as __tmp___ ${psql}', clearArgsAfterExec: false) |> callee
            }
        }finally{
            executor.clearSql(clearArgsAfterExec: true)
        }
    }
    public func page<R>(sql: String, size: Int64, page!: Int64 = 1): Pagination<R> where R <: QueryMappersInit<R> & DataFields<R> {
        selectPage<R>(sql, size, page){exe => exe.list<R>()}
    }
    public func singlePage<R>(sql: String, column: Int64, size: Int64, page!: Int64 = 1): Pagination<R> where R <: DataFields<R> {
        selectPage<R>(sql, size, page){exe => exe.singleList<R>(column)}
    }
    private func limit(size: Int64, offset!: Int64 = 0): String {
        let (one, two, sql) = dialect.limit(size, offset)
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
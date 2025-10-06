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

public sealed abstract class TableClause<T> where T <: QueryMappersInit<T> {
    let sqlgen = StringGenerator()
    private var idType_ = None<DataType>
    TableClause(partial: String, private let exe: SqlExecutor){
        for(mapper in T.queryMappers().mappers where mapper.isId){
            idType_ = mapper.dataType
            break
        }
        sqlgen.append(partial)
    }
    prop tableName: String {
        get(){
            T.tableName()
        }
    }
    public prop executor: SqlExecutor {
        get(){
            exe
        }
    }

    protected func appendPartial(prefix: String, partial: ()->String): This {
        if(let sql <- partial() && sql.size > 0){
            sqlgen.append(' ').append(prefix).append(' ').append(sql)
        }
        this
    }
    protected open func setSql(): SqlExecutor {
        executor.setSql(sqlgen.toString())
    }
    
    prop idType: ?DataType {
        get(){
            idType_
        }
    }
    prop dialect: SqlDialect {
        get(){
            SqlDialectMediator.instance.getDialect(exe.driverName)
        }
    }
}
public class FromClause<T> <: TableClause<T> where T <: QueryMappersInit<T> {
    init(executor: SqlExecutor){
        super(' from ${T.tableName()} ', executor)
    }
    public prop delete: Int64 {
        get(){
            executor.setSql('delete ${sqlgen}').delete
        }
    }
    private func join<T>(prefix: String, AS: String, ON: String): This where T <: QueryMappersInit<T> {
        sqlgen.append(' ').append(prefix).append(' join ').append(T.tableName())
        if(AS.size > 0){
            sqlgen.append(' AS ').append(AS)
        }
        if(ON.size > 0){
            sqlgen.append(' ON ').append(ON)
        }
        this
    }
    public func INNER_JOIN<T>(AS!: String = '', ON!: String = ''): This where T <: QueryMappersInit<T> {
        join<T>('inner', AS, ON)
    }
    public func LEFT_JOIN<T>(AS!: String = '', ON!: String = ''): This where T <: QueryMappersInit<T> {
        join<T>('left outer', AS, ON)
    }
    public func RIGHT_JOIN<T>(AS!: String = '', ON!: String = ''): This where T <: QueryMappersInit<T> {
        join<T>('right outer', AS, ON)
    }
    public func FULL_JOIN<T>(AS!: String = '', ON!: String = ''): This where T <: QueryMappersInit<T> {
        join<T>('full outer', AS, ON)
    }
    public func WHERE(condition: ()->String): This {
        appendPartial('where', condition)
    }
    public func GROUP_BY(groupBy: ()->String): This {
        appendPartial('group by', groupBy)
    }
    public func ORDER_BY(orderBy: ()->String): This {
        appendPartial('order by', orderBy)
    }
    public func first<T>(): ?T where T <: QueryMappersInit<T> {
        executor.setSql('select * ${sqlgen}').first<T>()
    }
    public func list<T>(): ArrayList<T> where T <: QueryMappersInit<T> {
        executor.setSql('select * ${sqlgen}').list<T>()
    }
    public func list<T>(size: Int64, offset!: Int64 = 0): ArrayList<T> where T <: QueryMappersInit<T> {
        let (one, two, sql) = dialect.limit(size, offset)
        this.executor.arg(one)
        this.executor.arg(two)
        executor.setSql('select * ${sqlgen} ${sql}').list<T>()
    }
    public func count(): Int64 {
        executor.setSql('select count(*) ${sqlgen}').first<Int64>() ?? 0
    }
}
public class UpdateClause<T> <: TableClause<T> where T <: QueryMappersInit<T> {
    init(executor: SqlExecutor){
        super('update ${T.tableName()} ', executor)
    }
    public func SET(set: ()->String): This {
        appendPartial('set', set)
    }
    public func WHERE(condition: ()->String): This {
        appendPartial('where', condition)
        this
    }
    public func ORDER_BY(orderBy: ()->String): This {
        appendPartial('order by', orderBy)
    }
    public func LIMIT(size: Int64, offset!: Int64 = 0): This {
        let (one, two, sql) = dialect.limit(size, offset)
        this.executor.arg(one)
        this.executor.arg(two)
        sqlgen.append(sql)
        this
    }
    public func execute(): Int64 {
        setSql().update
    }
}
public class IntoClause<T> <: TableClause<T> where T <: QueryMappersInit<T> {
    private let fields = ArrayList<DataType>()

    init(executor: SqlExecutor){
        super('insert into ${T.tableName()}(', executor)
        var i = 0
        for(mapper in T.queryMappers().mappers){
            if(i > 0){
                sqlgen.append(',')
            }
            sqlgen.append(mapper.dataType.columnName)
            fields.add(mapper.dataType)
            i++
        }
        sqlgen.append(')')
    }
    public func VALUES<D>(value: D): This where D <: ObjectData<D> {
        sqlgen.append('values(')
        let data = DataObject<D>(value)
        for(i in 0 .. fields.size){
            if(i > 0){
                sqlgen.append(',')
            }
            let field = fields[i]
            let val = data.get(field.fieldName)
            let holder = 
            match(val){
                case _: DataNone => this.executor.argNull()
                case x: DataBool => this.executor.arg(x.data)
                case x: DataString => this.executor.arg(x.data)
                case x: DataDuration => this.executor.arg(x.data)
                case x: DataDateTime => this.executor.arg(x.data)
                case x: DataCollection<Array<Byte>, Byte> => this.executor.arg(x.data)
                case x: DataReal => match(field){
                    case _: Int8DataType => this.executor.arg(x.toInt8())
                    case _: UInt8DataType => this.executor.arg(x.toUInt8())
                    case _: Int16DataType => this.executor.arg(x.toInt16())
                    case _: UInt16DataType => this.executor.arg(x.toUInt16())
                    case _: Int32DataType => this.executor.arg(x.toInt32())
                    case _: UInt32DataType => this.executor.arg(x.toUInt32())
                    case _: Int64DataType => this.executor.arg(x.toInt64())
                    case _: UInt64DataType => this.executor.arg(x.toUInt64())
                    case _: Float32DataType => this.executor.arg(x.toFloat32())
                    case _: Float64DataType => this.executor.arg(x.toFloat64())
                    case _: Float16DataType => this.executor.arg(x.toFloat16())
                    case _: DecimalDataType => this.executor.arg(x.toDecimal())
                    case _: BigIntDataType => this.executor.arg(x.toBigInt())
                    case x => throw SqlArgException('field ${field.fieldName} is a number, but ${TypeInfo.of(x)} is required.')
                }
                case x => throw SqlArgException('type of field ${field.fieldName} is ${TypeInfo.of(x)}, but it is not supported yet.')
            }
            sqlgen.append(holder)
        }
        sqlgen.append(')')
        if(let Some(idType) <- super.idType){
            sqlgen.append(dialect.lastInsertId(idType))
        }
        this
    }
    public func SELECT<T>(selectColumns: String, fromClause: (FromClause<T>)->FromClause<T>): This where T <: QueryMappersInit<T> {
        let from = fromClause(executor.FROM<T>())
        sqlgen.append('select ').append(selectColumns).append(from.sqlgen)
        this
    }
    public func execute(){
        setSql().insert
    }
}
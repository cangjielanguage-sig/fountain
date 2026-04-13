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
package fountain::f_orm.base

import std.reflect.*
import fountain::f_base.*
import fountain::f_data.*
import fountain::f_data.macros.*
import fountain::f_orm.exception.TableMetaException

public class TableMeta{
    private TableMeta(
        public let driver: String,
        public let database: String,
        public let tableName: String,
        public let columns: Array<ColumnMeta>,
        public let indexes: Array<IndexMeta>
    ){}
    public static func new<T>(): TableMeta where T <: QueryMappersInit<T> {
        let typeInfo = ClassTypeInfo.of<T>()
        let dbSchema = typeInfo.findAnnotation<DatabaseSchema>() ?? throw TableMetaException('annotation @DatabaseSchema is not found at decleration of ${typeInfo}')
        let database = dbSchema.database
        let driver = dbSchema.driverName
        let tableName = T.tableName()
        let indexes = typeInfo.findAllAnnotations<IndexSchema>().iterator().map{s => IndexMeta(s)}
            .fold(ArrayList<IndexMeta>(), {list, i => 
                list.add(i)
                list
            }).unsafeData()
        let columns = T.queryMappers().mappers.iterator().map{m: QueryMapper<T> =>
            try{
                let p = typeInfo.getInstanceProperty(m.fieldName)
                if(let Some(schema) <- p.findAnnotation<ColumnSchema>()){
                    return ColumnMeta(schema, m.columnName)
                }
            }catch(_){}
            try{
                let f = typeInfo.getInstanceVariable(m.fieldName)
                if(let Some(schema) <- f.findAnnotation<ColumnSchema>()){
                    return ColumnMeta(schema, m.columnName)
                }
            }catch(_){}
            None<ColumnMeta>
        }.filter{opt => opt.isSome()}.map{opt => opt.getOrThrow()}.fold(ArrayList<ColumnMeta>(), {list, c => 
            list.add(c)
            list
        }).unsafeData()
        TableMeta(driver, database, tableName, columns, indexes)
    }
}
@DataAssist[fields]
public class ColumnMeta <: Hashable & Equatable<ColumnMeta> {
    public var columnName: String = ''
    public var oldColumnName: String = ''
    public var typeName: String = ''
    public var nullable: Bool = false
    public var default: ?String = None
    public var extra: String = ''
    public var comment: String = ''
    public init(){}
    public init(schema: ColumnSchema, columnName: String){
        this.columnName = columnName
        this.oldColumnName = schema.oldColumnName
        this.typeName = schema.typeName
        this.nullable = schema.nullable
        this.default = schema.default
        this.extra = schema.extra
        this.comment = schema.comment
    }
    public func hashCode(): Int64 {
        HashBuilder().append(columnName).append(typeName).append(nullable).append(default).append(extra).build()
    }
    public operator func ==(other: ColumnMeta): Bool {
        columnName == other.columnName && 
        typeName == other.typeName && 
        nullable == other.nullable && 
        default == other.default && 
        extra == other.extra
    }
}
@DataAssist[fields]
public class IndexMeta <: Hashable & Equatable<IndexMeta> {
    public var name: String = ''
    public var columns: String = ''
    public var unique: Bool = false
    public var def: String = ''
    public init(){}
    public init(name: String, columns: String, unique: Bool){
        this.name = name
        this.columns = columns
        this.unique = unique
    }
    public init(schema: IndexSchema){
        name = schema.name
        columns = schema.columns
        unique = schema.unique
    }
    public func hashCode(): Int64 {
        HashBuilder().append(name).append(columns).append(unique).build()
    }
    public operator func ==(other: IndexMeta): Bool {
        name == other.name && 
        columns == other.columns && 
        unique == other.unique
    }
}
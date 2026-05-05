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
package fountain::f_orm.migro

import fountain::f_bean.*
import fountain::f_bean.macros.*
import fountain::f_data.*
import fountain::f_data.macros.*
import fountain::f_orm.base.*
import fountain::f_orm.macros.*

@DataAssist[fields]
@QueryMappersGenerator[table: 'columns']
public class PostgresTableSchemaPO {
    @ORMField['column_name']
    private var columnName: String = ''
    @ORMField['type_name']
    private var typeName: String = ''
    @ORMField['is_nullable']
    private var nullable: Bool = false
    @ORMField['generation_expression']
    private var generationExpression: String = ''
    @ORMField['column_default']
    private var default: ?String = None

    @ORMField['table_name']
    private var tableNameFromDb: String = ''

    public prop extra: String{
        get(){
            'generated always (${generationExpression}) STORED'
        }
    }
}
@DataAssist[fields]
@QueryMappersGenerator[table: 'indexes']
public class PostgresIndexSchemaPO {
    @ORMField['indexname']
    private var name: String = ''
    @ORMField['indexdef']
    private var indexdef: String = ''
    
    public prop columns: String {
        get(){
            let start = (indexdef.lastIndexOf('(') ?? -1) + 1
            let end = indexdef.lastIndexOf(')') ?? -1
            indexdef[start .. end]
        }
    }
    public prop unique: Bool {
        get(){
            indexdef.startsWith('CREATE UNIQUE')
        }
    }
}
public abstract class AbstractPostgresSchemaFinder <: SchemaFinder {
    private static func indexColumns(itr: Iterator<ColumnMeta>): HashMap<String, ColumnMeta> {
        itr.fold(HashMap<String, ColumnMeta>()){m, c => m[c.columnName] = c; m}
    }
    private static func indexIndexes(itr: Iterator<IndexMeta>): HashMap<String, IndexMeta> {
        itr.fold(HashMap<String, IndexMeta>()){m, i => m[i.name] = i; m}
    }
    public func listTables(database: String): Iterator<String> {
        resource(ORM.executor(driverName)){exe =>
            exe.setSql('''
            select table_name
              from information_schema.tables
             where table_catalog = ${exe.arg(database)}
               and table_schema = 'public' ''')
            .iterator<PostgresTableSchemaPO>()
            .map{po => po.tableNameFromDb}
        }
    }
    public func findTableSchema(database: String, tableName: String): Iterator<ColumnMeta> {
        resource(ORM.executor(driverName)){exe =>
            exe.setSql("""
            select column_name, 
                   concat(udt_name, case when character_maximum_length is not null 
                                         then concat('(', cast(character_maximum_length as varchar), ')')
                                         when numeric_precision is not null and numeric_scale is not null 
                                         then concat('(', cast(numeric_precision as varchar), ',', cast(numeric_scale as varchar), ')')
                                         otherwise ''
                                     end) as type_name, 
                   is_nullable, 
                   generation_expression,
                   column_default 
              from information_schema.columns
             where table_catalog = ${exe.arg(database)}
               and table_name = ${exe.arg(tableName)}""")
            .iterator<PostgresTableSchemaPO>()
            .map{po => DataObject<ColumnMeta>.populate(po.toData()).getOrThrow()}
        }
    }
    public func findIndexes(database: String, tableName: String): Iterator<IndexMeta> {
        resource(ORM.executor(driverName)){exe =>
            exe.setSql('''
            select indexname, indexdef
              from pg_indexes
             where tablename = ${exe.arg(tableName)}''')
            .iterator<PostgresIndexSchemaPO>()
            .map{po => 
                let indexName = po.name
                let unique = po.unique
                let columns = po.columns
                let meta = IndexMeta(indexName, columns, unique)
                meta.def = po.indexdef
                meta
            }
        }
    }
    private static func esc(val: String): String {
        val.replace("'", "''")
    }
    private func generateColumn(column: ColumnMeta): String {
        '${column.columnName} ${column.typeName} ${if(column.nullable){''}else{'not null'}} ${column.extra}'
    }
    public func generateCreateSql(tableName: String, columns: Iterator<ColumnMeta>): Iterator<String> {
        let list = columns.iterator().fold(ArrayList<ColumnMeta>()){l, m => 
            l.add(m)
            l
        }
        ['''
        create table ${tableName}(
            ${list.iterator().map{column => generateColumn(column)}.intersperse(',\n').fold(StringGenerator()){g, s => g.append(s)}}
        );
        '''].iterator().concat(
            list.iterator().filter{m => m.default.isSome()}.map{m => "ALTER TABLE ${tableName} ALTER ${m.columnName} SET DEFAULT '${esc(m.default.getOrThrow())}';"}
        )
    }
    public func generateDropTableSql(tableName: String): String {
        'drop table ${tableName};'
    }
    public func generateAlterSql(tableName: String, new: Array<ColumnMeta>, current: Iterator<ColumnMeta>): Iterator<String> {
        let currentColumnMap = indexColumns(current)
        let newColumnMap = HashMap<String, ColumnMeta>()
        let oldColumnMap = HashMap<String, ColumnMeta>()
        for(c in new){
            newColumnMap[c.columnName] = c
            if(c.oldColumnName != ''){
                oldColumnMap[c.oldColumnName] = c
            }
        }
        let sqls = ArrayList<String>()
        for(column in currentColumnMap.values()){
            if(let Some(c) <- oldColumnMap.get(column.columnName)){
                sqls.add('alter table ${tableName} rename column ${c.oldColumnName} to ${c.columnName};')
                sqls.add('alter table ${tableName} alter column ${c.columnName} type ${c.typeName};')
                if(c.default.isSome()){
                    sqls.add("alter table ${tableName} alter ${c.columnName} set default '${esc(c.default.getOrThrow())}';")
                }else{
                    sqls.add("alter table ${tableName} alter ${c.columnName} drop default;")
                }
                if(c.nullable){
                    sqls.add('alter table ${tableName} alter column ${c.columnName} drop not null;')
                }else{
                    sqls.add('alter table ${tableName} alter column ${c.columnName} set not null;')
                }
            }else if(!newColumnMap.contains(column.columnName)){
                sqls.add('alter table ${tableName} drop column ${column.columnName};')
            }
        }
        for(column in new){
            if(let Some(c) <- currentColumnMap.get(column.columnName)){
                if(column != c){
                    if(column.typeName != c.typeName || column.oldColumnName != ''){
                        sqls.add('alter table ${tableName} alter column ${column.columnName} type ${column.typeName};')
                    }
                    if(column.default.isSome()){
                        sqls.add("alter table ${tableName} alter ${c.columnName} set default '${esc(column.default.getOrThrow())}';")
                    }else{
                        sqls.add("alter table ${tableName} alter ${c.columnName} drop default;")
                    }
                    if(c.nullable){
                        sqls.add('alter table ${tableName} alter column ${c.columnName} drop not null;')
                    }else{
                        sqls.add('alter table ${tableName} alter column ${c.columnName} set not null;')
                    }
                }
            }else{
                sqls.add('alter table ${tableName} add column ${generateColumn(column)};')
                if(column.default.isSome()){
                    sqls.add("alter table ${tableName} alter ${column.columnName} set default '${esc(column.default.getOrThrow())}';")
                }
                if(!column.nullable){
                    sqls.add('alter table ${tableName} alter column ${column.columnName} set not null;')
                }
            }
        }
        sqls.iterator()
    }
    public func generateIndexSql(tableName: String, new: Array<IndexMeta>, current: Iterator<IndexMeta>): Iterator<String> {
        let currentIndexes = indexIndexes(current)
        let newIndexMap = indexIndexes(new.iterator())
        let sqls = ArrayList<String>()
        for(i in currentIndexes.values() where !newIndexMap.contains(i.name)){
            sqls.add('alter table ${tableName} drop index ${i.name};')
        }
        for(i in newIndexMap.values()){
            if(let Some(x) <- currentIndexes.get(i.name) && i != x){
                sqls.add('alter table ${tableName} drop index ${i.name};')
                sqls.add('${i.def};')
            }else if(!currentIndexes.contains(i.name)){
                sqls.add('${i.def};')
            }
        }
        sqls.iterator()
    }
}
@Bean
public class PostgresSchemaFinder <: AbstractPostgresSchemaFinder {
    public prop driverName: String {
        get(){
            'postgres'
        }
    }
}
@Bean
public class OpenGaussSchemaFinder <: AbstractPostgresSchemaFinder {
    public prop driverName: String {
        get(){
            'opengauss'
        }
    }
}

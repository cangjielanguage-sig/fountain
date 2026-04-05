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
public class MysqlTableSchemaPO {
    @ORMField['column_name']
    private var columnName: String = ''
    @ORMField['column_type']
    private var typeName: String = ''
    @ORMField['is_nullable']
    private var nullable: Bool = false
    @ORMField['extra']
    private var extra: String = ''
    @ORMField['column_default']
    private var default: ?String = None
}
@DataAssist[fields]
@QueryMappersGenerator[table: 'indexes']
public class MysqlIndexSchemaPO {
    @ORMField['index_name']
    private var name: String = ''
    @ORMField['column_name']
    private var column: String = ''
    @ORMField['is_unique']
    private var unique: Bool = false
}

public abstract class AbstractMysqlSchemaFinder <: SchemaFinder {
    public func findTableSchema(database: String, tableName: String): Iterator<ColumnMeta> {
        resource(ORM.executor(driverName)){exe =>
            exe.setSql('''
            select column_name, column_type, is_nullable, column_default, extra
              from information_schema.columns
             where table_schema = ${exe.arg(database)}
               and table_name = ${exe.arg(tableName)}''')
            .iterator<MysqlTableSchemaPO>()
            .map{po => DataObject<ColumnMeta>.populate(po.toData()).getOrThrow()}
        }
    }
    public func findIndexes(database: String, tableName: String): Iterator<IndexMeta> {
        resource(ORM.executor(driverName)){exe =>
            exe.setSql('''
            select index_name, column_name, non_unique = 0 as is_unique
              from information_schema.statistics
             where table_schema = ${exe.arg(database)}
               and table_name = ${exe.arg(tableName)}''')
            .iterator<MysqlIndexSchemaPO>()
            .groupBy{po => po.name}.iterator()
            .map{tuple => 
                let indexName = tuple[0]
                let unique = tuple[1][0].unique
                let columns = tuple[1].iterator().map{po => po.column}.intersperse(',').fold(StringGenerator()){g, s => g.append(s)}.toString()
                IndexMeta(indexName, columns, unique)
            }
        }
    }
    private func generateColumn(column: ColumnMeta): String {
        '${column.columnName} ${column.typeName} ${if(column.nullable){''}else{'not null'}} ${if(let Some(d) <- column.default){"default '${d}'"}else{''}} ${column.extra}'
    }
    public func generateCreateSql(tableName: String, columns: Iterator<ColumnMeta>): Iterator<String> {
        Some('''
        create table ${tableName}(
            ${columns.iterator().map{column => generateColumn(column)}.intersperse(',\n').fold(StringGenerator()){g, s => g.append(s)}}
        );
        ''').iterator()
    }
    public func generateAlterSql(tableName: String, new: Array<ColumnMeta>, current: Iterator<ColumnMeta>): Iterator<String> {
        let currentColumnMap = current.iterator().fold(HashMap<String, ColumnMeta>()){m, c => 
            m[c.columnName] = c
            m
        }
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
                sqls.add('alter table ${tableName} change ${c.oldColumnName} ${c.columnName} ${c.typeName} ${if(c.nullable){''}else{'not null'}} ${if(let Some(d) <- column.default){"default '${d}'"}else{''}} ${column.extra};')
            }else if(!newColumnMap.contains(column.columnName)){
                sqls.add('alter table ${tableName} drop column ${column.columnName};')
            }
        }
        for(column in new){
            if(let Some(c) <- currentColumnMap.get(column.columnName)){
                if(column != c){
                    sqls.add('alter table ${tableName} change ${column.columnName} ${column.columnName} ${column.typeName} ${if(column.nullable){''}else{'not null'}} ${if(let Some(d) <- column.default){"default '${d}'"}else{''}} ${column.extra};')
                }
            }else{
                sqls.add('alter table ${tableName} add column ${generateColumn(column)};')
            }
        }
        sqls.iterator()
    }
    public func generateIndexSql(tableName: String, new: Array<IndexMeta>, current: Iterator<IndexMeta>): Iterator<String> {
        let currentIndexes = current.iterator().fold(HashMap<String, IndexMeta>()){m, i => 
            m[i.name] = i
            m
        }
        let newIndexMap = new.iterator().fold(HashMap<String, IndexMeta>()){m, i => 
            m[i.name] = i
            m
        }
        let sqls = ArrayList<String>()
        for(i in currentIndexes.values() where !newIndexMap.contains(i.name)){
            sqls.add('alter table ${tableName} drop index ${i.name};')
        }
        for(i in newIndexMap.values()){
            if(let Some(x) <- currentIndexes.get(i.name) && i != x){
                sqls.add('alter table ${tableName} drop index ${i.name};')
                if(i.name == 'primary' || i.name == 'PRIMARY'){
                    sqls.add('ALTER TABLE ${tableName} ADD PRIMARY KEY (${i.columns});')
                }else{
                    sqls.add('alter table ${tableName} add ${if(i.unique){'unique'}else{'index'}} ${i.name} (${i.columns});')
                }
            }else if(!currentIndexes.contains(i.name)){
                sqls.add('alter table ${tableName} add ${if(i.unique){'unique'}else{'index'}} ${i.name} (${i.columns});')
            }
        }
        sqls.iterator()
    }
}
@Bean
public class MysqlSchemaFinder <: AbstractMysqlSchemaFinder {
    public prop driverName: String {
        get(){
            'mysql'
        }
    }
}
@Bean
public class MariaDBSchemaFinder <: AbstractMysqlSchemaFinder {
    public prop driverName: String {
        get(){
            'mysql'
        }
    }
}

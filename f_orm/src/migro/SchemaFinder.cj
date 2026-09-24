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

import fountain::f_data.macros.*
import fountain::f_orm.macros.*

public interface SchemaFinder { 
    prop driverName: String
    func listTables(database: String): Iterator<String>
    func findTableSchema(database: String, tableName: String): Iterator<ColumnMeta>
    func findIndexes(database: String, tableName: String): Iterator<IndexMeta>
    func generateCreateSql(tableName: String, columns: Iterator<ColumnMeta>): Iterator<String>
    func generateDropTableSql(tableName: String): String
    func generateAlterSql(tableName: String, new: Array<ColumnMeta>, current: Iterator<ColumnMeta>): Iterator<String>
    func generateIndexSql(tableName: String, new: Array<IndexMeta>, current: Iterator<IndexMeta>): Iterator<String>
}

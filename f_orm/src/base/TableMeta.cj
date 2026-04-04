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

public class TableMeta{
    private TableMeta(
        public let database: String,
        public let tableName: String,
        public let columns: Array<ColumnMeta>,
        public let indexes: Array<IndexMeta>
    ){}
    public static func new<T>(): TableMeta where T <: QueryMappersInit<T> {
        //todo
        throw Exception()
    }
}
public class ColumnMeta{
    public ColumnMeta(
        public let columnName: String,
        public let typeName: String,
        public let nullable: Bool,
        public let default: ?String,
        public let comment: String
    ){}
}
public class IndexMeta {
    public IndexMeta(
        public let indexName: String,
        public let columns: Array<String>,
        public let unique: Bool
    ){}
}
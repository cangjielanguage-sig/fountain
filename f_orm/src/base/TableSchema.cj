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

@Annotation[target: [Type]]
public class DatabaseSchema{
    public const DatabaseSchema(
        private let db!: String = ''
    ){}
    public prop database: String {
        get(){
            if(db.isEmpty()){
                ORM.defaultDriver
            }else{
                db
            }
        }
    }
}

@Annotation[target: [Type]]
public class IndexSchema{
    public const IndexSchema(
        public let name!: String,
        public let columns!: String,
        public let unique!: Bool
    ){}
}

@Annotation[target: [MemberProperty, MemberVariable]]
public class ColumnSchema{
    public const ColumnSchema(
        public let typeName!: String,
        public let nullable!: Bool = false,
        public let default!: ?String = None,
        public let comment!: String = ''
    ){}
}
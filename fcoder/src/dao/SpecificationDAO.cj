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
package fountain::fcoder.dao

import fountain::f_orm.macros.*

@DAO
public interface SpecificationDAO <: RootDAO {
    func findSpec(projectId: Int64, kind: SpecKind): ArrayList<String> {
        executor.setSql('''
            select content 
              from specification
             where project_id = ${arg(projectId)}
               and kind = ${arg(kind)}
        ''').singleList<String>()
    }
    func findSpecByTitle(projectId: Int64, kind: SpecKind, title: String): ?String{
        executor.setSql('''
            select content 
              from specification
             where project_id = ${arg(projectId)}
               and kind = ${arg(kind)}
               and title = ${arg(title)}
        ''').singleFirst<String>()
    }
}
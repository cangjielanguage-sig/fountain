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
package fountain::f_llm.model.po

import fountain::f_data
import fountain::f_data.*
import fountain::f_data.macros.*
import fountain::f_orm.*
import fountain::f_orm.macros.*
import fountain::f_llm.constant.*

@DataAssist[props fields]
@QueryMappersGenerator[table: agent_todo]
public class Todo {
    @ORMField[id column: 'id']
    private var id: Int64 = 0
    @ORMField['title']
    private var title: String = ''
    @ORMField['content']
    private var content: String = ''
    @ORMField['status']
    private var status: String = TODO_STATUS_PENDING
    @ORMField['predecessor']
    private var predecessors: String = ''

    public func predecessor(): ArrayList<Int64> {
        f_data.convert<ArrayList<Int64>>(JsonValue.fromStr(predecessors).toData()) ?? ArrayList<Int64>()
    }
    public func predecessor(value: ArrayList<Int64>): Unit {
        predecessors = f_data.convert<JsonValue>(value.toData()).getOrThrow().toString()
    }
}
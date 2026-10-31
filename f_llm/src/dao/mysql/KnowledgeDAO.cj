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
package fountain::f_llm.dao.mysql

import std.collection.*

import fountain::f_orm.*
import fountain::f_orm.macros.*

/** MySQL 知识文档 DAO（3.3）：同 docId 覆盖写。 */
@DAO
public interface MySqlKnowledgeDAO <: RootDAO {
    func docGet(docId: String): ?Map<String, Any> {
        let sql = '''
            SELECT title, content FROM llm_document WHERE doc_id = ${arg(docId)}
        '''
        let row = executor.setSql(sql).firstToMap()
        if(row.isEmpty()){
            None
        }else{
            Some<Map<String, Any>>(row)
        }
    }

    func docUpsert(docId: String, title: String, content: String): Unit {
        let sql = '''
            INSERT INTO llm_document (doc_id, title, content, update_time)
            VALUES (${arg(docId)}, ${arg(title)}, ${arg(content)}, UTC_TIMESTAMP())
            ON DUPLICATE KEY UPDATE
                title = VALUES(title),
                content = VALUES(content),
                update_time = UTC_TIMESTAMP()
        '''
        executor.setSql(sql).update
    }

    func docDelete(docId: String): Int64 {
        let sql = 'DELETE FROM llm_document WHERE doc_id = ${arg(docId)}'
        let deleted = executor.setSql(sql).update
        deleted
    }
}

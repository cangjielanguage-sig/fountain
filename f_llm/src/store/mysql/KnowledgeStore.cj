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
package fountain::f_llm.store.mysql

import fountain::f_orm.*

import fountain::f_llm.dao.mysql.*
import fountain::f_llm.store.*

/** MySQL 知识文档存储（3.3）。 */
public class MySqlKnowledgeStore <: KnowledgeStore & RootService {
    public init() {
    }

    public func upsert(doc: KnowledgeDoc): Unit {
        dao<MySqlKnowledgeDAO>('mysql').docUpsert(doc.docId, doc.title, doc.content)
    }

    public func get(docId: String): ?KnowledgeDoc {
        match(dao<MySqlKnowledgeDAO>('mysql').docGet(docId)){
            case Some(row) =>
                Some(KnowledgeDoc(docId, textOf(row.get('title')), textOf(row.get('content'))))
            case None => None
        }
    }

    public func remove(docId: String): Bool {
        dao<MySqlKnowledgeDAO>('mysql').docDelete(docId) > 0
    }
}

private func textOf(value: ?Any): String {
    match(value){
        case Some(raw) =>
            match(raw){
                case text: String => text
                case _ => ''
            }
        case None => ''
    }
}

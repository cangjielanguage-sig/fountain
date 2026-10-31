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

/** MySQL 知识文档存储：同 docId 覆盖写，按块建索引。 */
public class MySqlKnowledgeStore <: KnowledgeStore & RootService {
    private static let CANDIDATES: Int64 = 200

    public init() {
    }

    public func upsert(doc: KnowledgeDoc): Unit {
        let store = dao<MySqlKnowledgeDAO>('mysql')
        store.docUpsert(doc.docId, doc.title, doc.content)
        store.chunkDelete(doc.docId)
        var seq: Int64 = 0
        for(chunk in KnowledgeChunker.split(doc.content)){
            store.chunkInsert(doc.docId, seq, chunk)
            seq++
        }
    }

    public func get(docId: String): ?KnowledgeDoc {
        match(dao<MySqlKnowledgeDAO>('mysql').docGet(docId)){
            case Some(row) =>
                Some(KnowledgeDoc(docId, textOf(row.get('title')), textOf(row.get('content'))))
            case None => None
        }
    }

    public func remove(docId: String): Bool {
        let store = dao<MySqlKnowledgeDAO>('mysql')
        store.chunkDelete(docId)
        store.docDelete(docId) > 0
    }

    public func search(query: KnowledgeQuery): ArrayList<KnowledgeHit> {
        let terms = KnowledgeSearch.terms(query.text)
        if(terms.isEmpty()){
            return ArrayList<KnowledgeHit>()
        }
        let pattern = '%' + terms[0] + '%'
        let hits = ArrayList<KnowledgeHit>()
        for(row in dao<MySqlKnowledgeDAO>('mysql').chunkSearch(pattern, MySqlKnowledgeStore.CANDIDATES)){
            let docId = textOf(row.get('doc_id'))
            if(!wanted(query, docId)){
                continue
            }
            let content = textOf(row.get('content'))
            let score = KnowledgeSearch.score(content, terms)
            if(score <= 0.0f64){
                continue
            }
            hits.add(KnowledgeHit(docId, chunkIntOf(row.get('seq')), content, score))
        }
        KnowledgeSearch.rank(hits, query.limit)
    }

    private static func wanted(query: KnowledgeQuery, docId: String): Bool {
        if(query.docIds.isEmpty()){
            return true
        }
        for(item in query.docIds){
            if(item == docId){
                return true
            }
        }
        false
    }
}

private func chunkIntOf(value: ?Any): Int64 {
    match(value){
        case Some(raw) =>
            match(raw){
                case number: Int64 => number
                case number: Int32 => Int64(number)
                case _ => 0
            }
        case None => 0
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

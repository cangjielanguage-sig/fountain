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
public interface KnowledgeDAO <: RootDAO {
    func searchKnowledge(param: KnowledgeParam, embedding: Array<Float64>): ArrayList<String> {
        executor.setSql('''
            WITH confidence AS (
          SELECT id, title, content, kind, query, search_vector,
                 (1.0 - (embedding <=> ${arg(embedding.toString())})) * ${arg(param.embeddingWeight)} + 
                 ts_rank(search_vector, query) * (1.0 - ${arg(param.embeddingWeight)}) as confidence
            FROM knowledge, to_tsquery('chinese_english', ${arg(param.keywords)}) as query
         )
         SELECT content
           FROM confidence
          WHERE ${meet(param.kind.size > 0){'kind ${IN(param.kind)} AND '}}
                search_vector @@ query
            AND confidence >= ${arg(param.minConfidence)}
          ORDER
             BY confidence DESC
          LIMIT ${arg(param.maxResults)}
         OFFSET 0
        ''').singleList<String>()
    }
    func saveKnowledge(knowledge: Knowledge): Unit {
        executor.setSql('''
        insert 
          into knowledge(kind, md5, source, title, content, embedding)
        values(${arg(knowledge.kind)}, 
               ${arg(knowledge.md5)}, 
               ${arg(knowledge.source)}, 
               ${arg(knowledge.title)}, 
               ${arg(knowledge.content)}, 
               ${arg(knowledge.embedding)})
        on conflict(md5, code_lang, kind) do nothing
        ''').insert
    }
    func findKnowledge(kind: KnowledgeKind, title: String): ?String {
        executor.setSql('''
            select content
              from knowledge
             where kind = ${arg(kind)}
               and title = ${arg(title)}
        ''').singleFirst<String>()
    }
}
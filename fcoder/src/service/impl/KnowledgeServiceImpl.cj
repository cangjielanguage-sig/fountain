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
package fountain::fcoder.service.impl

import fountain::f_aspect.macros.*
import fountain::f_orm.macros.*
import fountain::fcoder.util

@TransactionalService
public class KnowledgeServiceImpl <: KnowledgeService {
    @Transactional
    public func search(content: String, kind: Array<KnowledgeKind>, size: Int64): ArrayList<String> {
        let exe = executor()
        KnowledgeEntity(
            content: content, kind: kind, size: size, 
            searchExecutor: exe.searchKnowledge, 
            llmAccessor: LLMContextMediator.instance.access, 
            embeddingAccessor: EmbeddingContextMediator.instance.access,
            usageSaver: exe.saveTokenUsage)
            .queryConf(exe.listConfs)
            .search{conf, content => util.search(conf.url, conf.conf, content, size)}
            .save(knowledgeSaver: exe.saveKnowledge)
    }
    @Transactional
    public func saveKnowledge(knowledge: Knowledge): Unit {
        executor().saveKnowledge(knowledge)
    }
    public func findKnowledge(kind: KnowledgeKind, title: String): ?String {
        executor().findKnowledge(kind, title)
    }
}
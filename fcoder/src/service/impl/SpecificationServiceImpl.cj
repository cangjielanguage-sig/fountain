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

@TransactionalService
public class SpecificationServiceImpl <: SpecificationService {
    public func findSpec(projectId: Int64, kind: SpecKind): ArrayList<String> {
        executor().findSpec(projectId, kind)
    }

    public func findSpecByTitle(projectId: Int64, kind: SpecKind, title: String): ?String {
        executor().findSpecByTitle(projectId, kind, title)
    }

    @Transactional
    public func saveSpecification(spec: Specification): Unit {
        let resp = EmbeddingContextMediator.instance.access(MODEL_NAME_GLM_EMBEDDING3, EmbeddingParam(
            agentId: spec.agentId,
            skillId: spec.skillId,
            input: '''
${spec.title}

${spec.content}
'''
        ))
        let embedding = resp.embedding
        let usage = resp.usage
        usage.agentId = spec.agentId
        usage.skillId = spec.skillId
        let exe = executor()
        exe.saveTokenUsage(usage)
        exe.saveSpecification(spec, embedding)
    }
}
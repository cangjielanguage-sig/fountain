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
public class CodeServiceImpl <: CodeService {
    public func findCodes(params: CodeParam): ArrayList<String> {
        let embeddingParams = EmbeddingParam(
            agentId: params.agentId,
            session: params.session,
            input: params.code
        )
        let resp = EmbeddingContextMediator.instance.access(MODEL_NAME_GLM_EMBEDDING3, embeddingParams)
        let embedding = resp.embedding
        let usage = resp.usage
        let exe = executor()
        exe.saveTokenUsage(usage)
        exe.findCodes(params, embedding)
    }
    @Transactional
    public func saveCode(code: Code): Unit {
        let embeddingParams = EmbeddingParam(
            agentId: code.agentId,
            session: code.session,
            input: code.code
        )
        let resp = EmbeddingContextMediator.instance.access(MODEL_NAME_GLM_EMBEDDING3, embeddingParams)
        let embedding = resp.embedding
        let usage = resp.usage
        let exe = executor()
        exe.saveTokenUsage(usage)
        exe.saveCode(code, embedding)
    }
}
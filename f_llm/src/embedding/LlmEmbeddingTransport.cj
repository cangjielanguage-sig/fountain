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
package fountain::f_llm.embedding

import std.collection.*

import fountain::f_llm.store.*

/**
 * 复用现有 `Embedding`（OpenAI 兼容 `/embeddings`、失败转移、熔断）的传输层实现。
 *
 * 只返回 dense：OpenAI 兼容端点没有 `lexical_weights` / `colbert_vecs` 字段。
 * 需要三路时用 `BgeM3Transport`（默认实现）；用本类时检索会标 `degraded`、`rerank` 失效。
 */
public class LlmEmbeddingTransport <: EmbeddingTransport {
    private let llmName: String
    private let agentId: Int64
    private let session: String

    public init(llmName!: String = 'bge-m3', agentId!: Int64 = 0, session!: String = '') {
        this.llmName = llmName
        this.agentId = agentId
        this.session = session
    }

    public func embed(text: String): EmbeddingResponse {
        let response = Embedding.embed(llmName,
            EmbeddingParam(agentId: agentId, session: session, input: text))
        EmbeddingResponse(response.embedding)
    }
}

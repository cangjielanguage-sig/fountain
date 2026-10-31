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

import fountain::f_bean.*
import fountain::f_bean.macros.*

import fountain::f_llm.store.*

/** 生产用 `Embedder`：`HttpEmbedder` + 复用 `Embedding` 的传输层，供 `lookup<Embedder>()` 取用。 */
@Bean
public class DefaultEmbedder <: Embedder {
    private let inner: Embedder

    public init() {
        // 本机 BGE-M3 服务支持三路；换成 OpenAI 兼容端点时改回 LlmEmbeddingTransport
        this.inner = HttpEmbedder(BgeM3Transport())
    }

    public func embed(text: String): Array<Float64> {
        inner.embed(text)
    }

    public func embedColbert(text: String): Array<Array<Float64>> {
        inner.embedColbert(text)
    }

    public func tokenize(text: String): HashMap<Int64, Float64> {
        inner.tokenize(text)
    }
}

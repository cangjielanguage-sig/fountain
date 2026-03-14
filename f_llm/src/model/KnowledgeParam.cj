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
package fountain::f_llm.model

public class KnowledgeParam {
    public KnowledgeParam(
        public let agentId!: Int64,
        public let session!: String,
        public let keywords!: String, 
        public let embeddingWeight!: Float64 = 0.7, 
        public let kind!: Array<KnowledgeKind> = [], 
        public let minConfidence!: Float64 = 0.8, 
        public let maxResults!: Int64 = 10
    ){}
}
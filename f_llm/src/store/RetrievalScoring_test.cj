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
package fountain::f_llm.store

import std.unittest.*
import std.unittest.testmacro.*

/** 打分口径的唯一来源：常量与算式变了会在这里先红 */
@Test
class RetrievalScoring_test {
    @TestCase
    func testMemoryFusionKeepsExistingWeights(): Unit {
        // 重构前：0.7 * dense + 0.3 * sparse
        @Expect(RetrievalScoring.fuseMemory(1.0f64, 0.0f64), 0.7f64)
        @Expect(RetrievalScoring.fuseMemory(0.0f64, 1.0f64), 0.3f64)
        @Expect(RetrievalScoring.fuseMemory(1.0f64, 1.0f64), 1.0f64)
    }

    @TestCase
    func testMemoryRerankWeightsTitleAndContent(): Unit {
        @Expect(RetrievalScoring.rerank(1.0f64, 0.0f64), 0.4f64)
        @Expect(RetrievalScoring.rerank(0.0f64, 1.0f64), 0.6f64)
    }

    @TestCase
    func testKnowledgeFusionAddsCappedLexical(): Unit {
        // 命中 2 次：0.9 + 0.1 * 2 = 1.1（浮点比较给容差）
        let score = RetrievalScoring.fuseKnowledge(0.9f64, 2.0f64)
        @Expect(score > 1.0999f64 && score < 1.1001f64, true)
    }

    @TestCase
    func testKnowledgeLexicalIsCapped(): Unit {
        // 命中 12 次与命中 5 次同分：上限生效，长文档堆词刷不动分
        let capped = RetrievalScoring.fuseKnowledge(0.5f64, 12.0f64)
        let atCap = RetrievalScoring.fuseKnowledge(0.5f64, 5.0f64)
        @Expect(capped, atCap)
        @Expect(capped > 0.9999f64 && capped < 1.0001f64, true)
    }

    @TestCase
    func testConstantsStayInSyncWithDocs(): Unit {
        @Expect(RetrievalScoring.MEMORY_DENSE_WEIGHT, 0.7f64)
        @Expect(RetrievalScoring.MEMORY_SPARSE_WEIGHT, 0.3f64)
        @Expect(RetrievalScoring.RERANK_TITLE_WEIGHT, 0.4f64)
        @Expect(RetrievalScoring.RERANK_CONTENT_WEIGHT, 0.6f64)
        @Expect(RetrievalScoring.LEXICAL_WEIGHT, 0.1f64)
        @Expect(RetrievalScoring.LEXICAL_CAP, 5.0f64)
    }
}

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
package fountain::f_llm.loom

import std.unittest.*
import std.unittest.testmacro.*

import fountain::f_llm.store.*

/** 技能检索：向量优先、关键词兜底 */
@Test
class SkillCatalog_test {
    private static func store(): InMemoryMetaStore {
        let meta = InMemoryMetaStore()
        meta.skills.upsert(Skill(1, '日报助手', '先列三段式，再给数据，最后给结论', '{}', version: 1))
        meta.skills.upsert(Skill(2, '代码评审', '只挑错，不夸奖，必须给出修改建议', '{}', version: 1))
        meta
    }

    /** 没有 embedder：走关键词 */
    @TestCase
    func testKeywordSearchPicksMatchingSkill(): Unit {
        let meta = store()
        SkillCatalog.install({ => meta.skills })
        try{
            @Expect(SkillCatalog.isVectorized(), false)
            let hits = SkillCatalog.search('日报', topK: 3)
            @Expect(hits.size > 0, true)
            @Expect(hits[0].title, '日报助手')
            @Expect(SkillCatalog.search('完全不相关的词', topK: 3).size, 0)
        }finally{
            SkillCatalog.reset()
        }
    }

    /** 有 embedder：走余弦相似度，且按分数排序 */
    @TestCase
    func testVectorSearchRanksBySimilarity(): Unit {
        let meta = store()
        // 假编码器：含「日报」→ 第一维，含「代码」→ 第二维
        let encode = { text: String =>
            if(text.contains('日报') || text.contains('三段式')){
                [1.0f64, 0.0f64]
            }else if(text.contains('代码') || text.contains('评审')){
                [0.0f64, 1.0f64]
            }else{
                [0.5f64, 0.5f64]
            }
        }
        SkillCatalog.install({ => meta.skills }, embedder: encode)
        try{
            @Expect(SkillCatalog.isVectorized(), true)
            let hits = SkillCatalog.search('日报', topK: 1, minScore: 0.5)
            @Expect(hits.size, 1)
            @Expect(hits[0].title, '日报助手')
            @Expect(hits[0].score > 0.9f64, true)
        }finally{
            SkillCatalog.reset()
        }
    }

    /** 编码器抛错：整体退回关键词，不能让技能不可用 */
    @TestCase
    func testEmbedderFailureFallsBackToKeyword(): Unit {
        let meta = store()
        let broken = { text: String =>
            throw IllegalStateException('embedding service down')
        }
        SkillCatalog.install({ => meta.skills }, embedder: broken)
        try{
            let hits = SkillCatalog.search('日报', topK: 3)
            @Expect(hits.size > 0, true)
            @Expect(hits[0].title, '日报助手')
            // 降级要能被看见：曾经的「装了编码器却在跑关键词」就是靠这个计数发现的
            let (queryFails, skillFails) = SkillCatalog.embedFailureDetail()
            @Expect(queryFails, 1)
            @Expect(skillFails, 0)
            @Expect(SkillCatalog.embedFailures(), 1)
        }finally{
            SkillCatalog.reset()
        }
    }

    /** 没装目录时返回空，而不是抛错 */
    @TestCase
    func testSearchWithoutCatalogReturnsEmpty(): Unit {
        SkillCatalog.reset()
        @Expect(SkillCatalog.search('日报').size, 0)
    }
}

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

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

import fountain::f_llm.store.*

/**
 * 检索**质量**（而不是「能返回结果」）：用固定语料 + 固定编码器算 recall@1 与 MRR。
 *
 * 为什么用假编码器：真实 embedding 取决于模型版本与网络，跑 CI 不可能稳定复现。
 * 假编码器把「语义相近」编码成同一个基向量，能稳定验证**排序逻辑**是否正确；
 * 真实语义效果属于离线评测集，不在单测范围内。
 */
@Test
class RetrievalQuality_test {

    /** 三个主题各两条技能，主题内语义相近、主题间正交 */
    private static func corpus(): InMemoryMetaStore {
        let meta = InMemoryMetaStore()
        meta.skills.upsert(Skill(1, '日报助手', '三段式：结论、数据、建议', '{}', version: 1))
        meta.skills.upsert(Skill(2, '周报助手', '按项目汇总进展与风险', '{}', version: 1))
        meta.skills.upsert(Skill(3, '代码评审', '只挑错，给出修改建议', '{}', version: 1))
        meta.skills.upsert(Skill(4, '重构建议', '识别坏味道并给出重构步骤', '{}', version: 1))
        meta.skills.upsert(Skill(5, '股票分析', '看财报、估值与风险', '{}', version: 1))
        meta.skills.upsert(Skill(6, '基金组合', '按风险偏好做资产配置', '{}', version: 1))
        meta
    }

    /** 主题 → 单位向量（三维正交基），主题内相近但不相同 */
    private static func encoder(): (String) -> Array<Float64> {
        { text =>
            if(text.contains('日报') || text.contains('三段式')){
                [0.99f64, 0.10f64, 0.0f64]
            }else if(text.contains('周报') || text.contains('项目')){
                [0.90f64, 0.20f64, 0.0f64]
            }else if(text.contains('代码') || text.contains('重构') || text.contains('评审')){
                [0.0f64, 0.98f64, 0.15f64]
            }else if(text.contains('股票') || text.contains('基金') || text.contains('财报')){
                [0.0f64, 0.12f64, 0.99f64]
            }else{
                [0.33f64, 0.33f64, 0.33f64]
            }
        }
    }

    private static func queries(): Array<String> {
        ['帮我写日报', '这段代码要评审', '看看股票财报']
    }

    private static func expected(): Array<String> {
        ['日报助手', '代码评审', '股票分析']
    }

    /** 向量模式下 recall@1 与 MRR 都必须满分 */
    @TestCase
    func testVectorRecallAt1IsPerfect(): Unit {
        let meta = corpus()
        SkillCatalog.install({ => meta.skills }, embedder: encoder())
        try{
            var hits = 0
            var reciprocal = 0.0f64
            let wanted = expected()
            let asked = queries()
            for(index in 0..asked.size){
                let ranked = SkillCatalog.search(asked[index], topK: 3, minScore: 0.2)
                if(ranked.size > 0 && ranked[0].title == wanted[index]){
                    hits++
                }
                for(rank in 0..ranked.size){
                    if(ranked[rank].title == wanted[index]){
                        reciprocal += 1.0f64 / Float64(rank + 1)
                        break
                    }
                }
            }
            let recall = Float64(hits) / Float64(asked.size)
            let mrr = reciprocal / Float64(asked.size)
            @Expect(recall, 1.0f64)
            @Expect(mrr, 1.0f64)
        }finally{
            SkillCatalog.reset()
        }
    }

    /** 无编码器时退化为关键词：允许下降，但不能全错 */
    @TestCase
    func testKeywordFallbackKeepsMostRecall(): Unit {
        let meta = corpus()
        SkillCatalog.install({ => meta.skills })
        try{
            @Expect(SkillCatalog.isVectorized(), false)
            var hits = 0
            let wanted = expected()
            let asked = queries()
            for(index in 0..asked.size){
                let ranked = SkillCatalog.search(asked[index], topK: 3, minScore: 0.2)
                if(ranked.size > 0 && ranked[0].title == wanted[index]){
                    hits++
                }
            }
            let recall = Float64(hits) / Float64(asked.size)
            // 「帮我写日报」能命中「日报助手」（标题覆盖），「这段代码要评审」能命中「代码评审」；
            // 「看看股票财报」对「股票分析」只能靠字符覆盖，阈值可能挡住——所以按 2/3 卡下限
            @Expect(recall >= 0.66f64, true)
        }finally{
            SkillCatalog.reset()
        }
    }

    /** 归属发现的质量：同主题经验必须都归到对应技能，不能串台 */
    @TestCase
    func testMatcherAssignsSameTopicTogether(): Unit {
        let skills = ArrayList<Skill>([
            Skill(1, '日报助手', '三段式：结论、数据、建议', '{}', version: 1),
            Skill(2, '代码评审', '只挑错，给出修改建议', '{}', version: 1)
        ].toArray())
        let experiences = ArrayList<ExperienceItem>([
            ExperienceItem(1, '日报 先列数据再给结论'),
            ExperienceItem(2, '日报 三段式更好读'),
            ExperienceItem(3, '代码评审 要说清为什么'),
            ExperienceItem(4, '代码评审 给具体改法')
        ].toArray())

        let result = SkillMatcher.assign(experiences, skills, embedder: Some(encoder()),
                                        threshold: 0.5)
        var daily = 0
        var review = 0
        for(item in result.assignments){
            for(experience in item.experiences){
                if(experience.content.contains('日报')){
                    @Expect(item.skillTitle, '日报助手')
                    daily++
                }else{
                    @Expect(item.skillTitle, '代码评审')
                    review++
                }
            }
        }
        @Expect(daily, 2)
        @Expect(review, 2)
        // 全部归到既有技能，不应产生新技能候选
        @Expect(result.candidates.size, 0)
    }
}

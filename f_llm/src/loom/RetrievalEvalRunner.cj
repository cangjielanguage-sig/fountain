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

import fountain::f_llm.embedding.DefaultEmbedder
import fountain::f_llm.store.*

/** 一轮真实评测的结果：报告文本 + 编码失败次数（>0 说明结果不可信） */
public class EvalOutcome {
    public let report: String
    public let embedFailures: Int64

    public init(report: String, embedFailures: Int64) {
        this.report = report
        this.embedFailures = embedFailures
    }
}

/**
 * 真实模型评测的可运行入口：灌语料 → 装编码器 → 分组评测 → 返回报告文本。
 *
 * 与 `RetrievalEval` 的分工：`RetrievalEval` 只做「给定检索函数算指标」，
 * 这里负责把语料、编码器、技能目录接起来，让调用方一行就能跑。
 *
 * 编码器用 `DefaultEmbedder`（读 `llm_embeddingUrl`，默认本机 8000 的 BGE-M3），
 * **不用** `SkillCatalog.embeddingEncoder`——后者依赖 `LLMConfs` 里的平台配置，
 * 没配时会在 `search` 内部静默退回关键词，评测就变成「以为在测向量，其实在测关键词」。
 */
public class RetrievalEvalRunner {
    private init() {
    }

    /** 把评测语料灌进技能库（标题=文档标题，正文=文档正文）；返回导入条数 */
    public static func loadCorpus(meta: MetaStore, docs: ArrayList<EvalDoc>): Int64 {
        // 先清空：重复跑时同名技能会叠版本，检索结果不可比
        for(skill in meta.skills.list()){
            let _ = meta.skills.remove(skill.id)
        }
        var id: Int64 = 1
        var count: Int64 = 0
        for(doc in docs){
            meta.skills.upsert(Skill(id, doc.title, doc.content, '{}', version: 1))
            id++
            count++
        }
        count
    }

    /** 标题 → 语料 id：`SkillCatalog` 只返回标题，评测量以语料 id 为准 */
    public static func titleToId(docs: ArrayList<EvalDoc>): HashMap<String, String> {
        let map = HashMap<String, String>()
        for(doc in docs){
            map[doc.title] = doc.id
        }
        map
    }

    /**
     * 跑一轮完整评测。
     *
     * @param dir 评测数据目录（含 retrieval_corpus.tsv / retrieval_queries.tsv）
     * @param modelName 仅用于报告标注；实际编码器是 `DefaultEmbedder`
     * @param minScore 低于该分数不返回；负样本靠它筛掉噪声
     */
    public static func run(meta: MetaStore, dir: String, modelName: String,
                           minScore!: Float64 = 0.2, topK!: Int64 = 5): EvalOutcome {
        let docs = RetrievalEval.readCorpus('${dir}/retrieval_corpus.tsv')
        let cases = RetrievalEval.readCases('${dir}/retrieval_queries.tsv')
        let imported = loadCorpus(meta, docs)
        let idOf = titleToId(docs)

        let embedder = DefaultEmbedder()
        let encode: (String) -> Array<Float64> = { text => embedder.embed(text) }
        SkillCatalog.reset()
        SkillCatalog.install({ => meta.skills }, embedder: Some(encode))
        let search = { query: String, k: Int64 =>
            let ids = ArrayList<String>()
            for(hit in SkillCatalog.search(query, topK: k, minScore: minScore)){
                match(idOf.get(hit.title)){
                    case Some(id) => ids.add(id)
                    case None => ()
                }
            }
            ids
        }

        let hard = ArrayList<EvalCase>()
        let multi = ArrayList<EvalCase>()
        let templated = ArrayList<EvalCase>()
        for(item in cases){
            if(item.isNegative()){
                continue
            }
            match(item.topic){
                case 'hard' => hard.add(item)
                case 'multi' => multi.add(item)
                case _ => templated.add(item)
            }
        }

        var text = 'corpus=${imported} cases=${cases.size} encoder=${modelName} '
        text += 'minScore=${minScore}\n'
        text += RetrievalEval.evaluate(cases, search, topK: topK).render('all')
        text += RetrievalEval.evaluate(templated, search, topK: topK).render('templated')
        text += RetrievalEval.evaluate(hard, search, topK: topK).render('hard（语义能力）')
        text += RetrievalEval.evaluate(multi, search, topK: topK).render('multi（多相关）')

        let (queryFails, skillFails) = SkillCatalog.embedFailureDetail()
        let failures = queryFails + skillFails
        if(failures > 0){
            text += 'WARN 编码失败 query=${queryFails} skill=${skillFails}：'
            text += '已静默退回关键词，本次结果不代表向量检索\n'
        }
        SkillCatalog.reset()
        EvalOutcome(text, failures)
    }
}

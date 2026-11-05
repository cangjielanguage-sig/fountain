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

/**
 * 评测骨架自身的用例：指标算得对、随附数据集格式正确且「可被检索到」。
 *
 * 这里不断言真实模型的质量——那需要网络与固定模型版本，属于离线评测；
 * 这里守住的是：脚本没写错、数据集没退化（query 与期望文档还对应得上）。
 */
@Test
class RetrievalEval_test {

    private static func cases(pairs: Array<(String, String)>): ArrayList<EvalCase> {
        let result = ArrayList<EvalCase>()
        for((query, expected) in pairs){
            result.add(EvalCase(query, ArrayList<String>([expected])))
        }
        result
    }

    /** 全部命中第 1 名：recall@1 = recall@k = 1，MRR = 1 */
    @TestCase
    func testPerfectRetrieverScoresOne(): Unit {
        let evalCases = cases([('q1', 'd1'), ('q2', 'd2')])
        let search = { query: String, topK: Int64 =>
            ArrayList<String>([if(query == 'q1'){ 'd1' }else{ 'd2' }])
        }
        let report = RetrievalEval.evaluate(evalCases, search, topK: 5)
        @Expect(report.recallAt1(), 1.0f64)
        @Expect(report.recallAtK(), 1.0f64)
        @Expect(report.mrr(), 1.0f64)
        @Expect(report.misses.size, 0)
    }

    /** 命中第 2 名：recall@1 = 0，recall@k = 1，MRR = 0.5 */
    @TestCase
    func testRankTwoGivesHalfMrr(): Unit {
        let evalCases = cases([('q1', 'd1')])
        let search = { _: String, _: Int64 => ArrayList<String>(['x', 'd1', 'y']) }
        let report = RetrievalEval.evaluate(evalCases, search, topK: 5)
        @Expect(report.recallAt1(), 0.0f64)
        @Expect(report.recallAtK(), 1.0f64)
        @Expect(report.mrr(), 0.5f64)
    }

    /** 未命中：计入 misses，指标为 0 */
    @TestCase
    func testMissIsRecorded(): Unit {
        let evalCases = cases([('找不到的查询', 'd1')])
        let search = { _: String, _: Int64 => ArrayList<String>(['x', 'y']) }
        let report = RetrievalEval.evaluate(evalCases, search, topK: 5)
        @Expect(report.recallAtK(), 0.0f64)
        @Expect(report.misses.size, 1)
        @Expect(report.misses[0], '找不到的查询')
        @Expect(report.render('demo').contains('misses(1)'), true)
    }

    /** 空用例集不能除零 */
    @TestCase
    func testEmptyCasesAreSafe(): Unit {
        let search = { _: String, _: Int64 => ArrayList<String>() }
        let report = RetrievalEval.evaluate(ArrayList<EvalCase>(), search, topK: 5)
        @Expect(report.recallAt1(), 0.0f64)
        @Expect(report.mrr(), 0.0f64)
    }

    /** 随附数据集：20 条语料 + 20 条 query，id 唯一，期望 id 都存在 */
    @TestCase
    func testShippedDatasetIsWellFormed(): Unit {
        let dir = evalDir()
        let docs = RetrievalEval.readCorpus('${dir}/retrieval_corpus.tsv')
        let evalCases = RetrievalEval.readCases('${dir}/retrieval_queries.tsv')
        @Expect(docs.size, 20)
        @Expect(evalCases.size, 20)

        let ids = HashSet<String>()
        for(doc in docs){
            @Expect(ids.contains(doc.id), false)
            ids.add(doc.id)
            @Expect(doc.title.isEmpty(), false)
        }
        for(item in evalCases){
            @Expect(item.query.isEmpty(), false)
            for(expected in item.expected){
                @Expect(ids.contains(expected), true)
            }
        }

        // 覆盖检查：每条语料都要被至少一条 query 引用。
        // 只加文档不加 query，指标不会下降——覆盖率却会静默漏掉一批主题。
        let referenced = HashSet<String>()
        for(item in evalCases){
            for(expected in item.expected){
                referenced.add(expected)
            }
        }
        for(doc in docs){
            @Expect(referenced.contains(doc.id), true)
        }
    }

    /**
     * 数据集「可检索」：用一个最笨的字符重合打分器跑一遍，recall@5 不能太低。
     *
     * 这条挡的不是模型质量，而是**数据集退化**——比如 query 与期望文档完全对不上，
     * 或换了文档 id 忘了改 query 文件。
     */
    @TestCase
    func testShippedDatasetIsRetrievable(): Unit {
        let dir = evalDir()
        let docs = RetrievalEval.readCorpus('${dir}/retrieval_corpus.tsv')
        let evalCases = RetrievalEval.readCases('${dir}/retrieval_queries.tsv')

        let search = { query: String, topK: Int64 =>
            let wanted = HashSet<Rune>()
            for(rune in query.runes()){
                wanted.add(rune)
            }
            let scored = ArrayList<(String, Int64)>()
            for(doc in docs){
                var score: Int64 = 0
                for(rune in doc.title.runes()){
                    if(wanted.contains(rune)){
                        score += 2
                    }
                }
                for(rune in doc.content.runes()){
                    if(wanted.contains(rune)){
                        score++
                    }
                }
                scored.add((doc.id, score))
            }
            // 选择排序取前 topK（语料只有 20 条）
            for(left in 0..scored.size){
                var best = left
                for(right in left + 1..scored.size){
                    if(scored[right][1] > scored[best][1]){
                        best = right
                    }
                }
                if(best != left){
                    let temp = scored[left]
                    scored[left] = scored[best]
                    scored[best] = temp
                }
            }
            let ranked = ArrayList<String>()
            var index: Int64 = 0
            while(index < Int64(scored.size) && index < topK){
                ranked.add(scored[index][0])
                index++
            }
            ranked
        }

        let report = RetrievalEval.evaluate(evalCases, search, topK: 5)
        // 字符重合已经很接近关键词检索的下限；低于 60% 说明数据集本身出了问题
        @Expect(report.recallAtK() >= 0.6f64, true)
    }

    /** cjpm test 的工作目录是模块根（f_llm/），兼容从上级目录跑的情况 */
    private static func evalDir(): String {
        let direct = RetrievalEval.defaultDir()
        try{
            let _ = RetrievalEval.readCorpus('${direct}/retrieval_corpus.tsv')
            return direct
        }catch(error: Exception){
            return '../eval'
        }
    }
}

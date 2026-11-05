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

    /** 多相关标注：命中任一期望文档即算对，排名取最靠前的那个 */
    @TestCase
    func testMultiExpectedHitsAny(): Unit {
        let evalCases = ArrayList<EvalCase>([
            EvalCase('多相关', ArrayList<String>(['a', 'b', 'c']), topic: 'multi')
        ].toArray())
        // 三个期望里只命中了 b，且排第 2
        let search = { _: String, _: Int64 => ArrayList<String>(['x', 'b', 'y']) }
        let report = RetrievalEval.evaluate(evalCases, search, topK: 5)
        @Expect(report.recallAt1(), 0.0f64)
        @Expect(report.recallAtK(), 1.0f64)
        @Expect(report.mrr(), 0.5f64)
        @Expect(report.misses.size, 0)
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

    /**
     * 随附数据集：50 条语料 + 462 条正样本（300 模板化 + 150 难样本 + 12 多相关）+ 10 条负样本。
     *
     * 规模是按「单主题结论」定的：10 个模板化主题各 30 条、难样本每文档 3 条；
     * 全局 462 条约 ±3.5 点，够做换模型的粗判。要卡 5 点级回归仍需 500+，见 doc。
     */
    @TestCase
    func testShippedDatasetIsWellFormed(): Unit {
        let dir = evalDir()
        let docs = RetrievalEval.readCorpus('${dir}/retrieval_corpus.tsv')
        let evalCases = RetrievalEval.readCases('${dir}/retrieval_queries.tsv')
        @Expect(docs.size, 50)

        let ids = HashSet<String>()
        for(doc in docs){
            @Expect(ids.contains(doc.id), false)
            ids.add(doc.id)
            @Expect(doc.title.isEmpty(), false)
        }

        let queries = HashSet<String>()
        let referenced = HashSet<String>()
        let perTopic = HashMap<String, Int64>()
        var negatives: Int64 = 0
        for(item in evalCases){
            // query 不重复，否则指标被同一句重复加权
            @Expect(queries.contains(item.query), false)
            queries.add(item.query)
            if(item.isNegative()){
                negatives++
                @Expect(item.topic, 'negative')
                continue
            }
            @Expect(item.topic.isEmpty(), false)
            perTopic[item.topic] = (perTopic.get(item.topic) ?? 0) + 1
            for(expected in item.expected){
                @Expect(ids.contains(expected), true)
                referenced.add(expected)
            }
        }

        @Expect(negatives, 10)
        @Expect(evalCases.size - negatives, 462)
        // 12 个主题：10 个模板化主题各至少 30 条、难样本每文档 3 条、多相关 12 条
        @Expect(perTopic.size, 12)
        for((topic, count) in perTopic){
            if(topic == 'hard'){
                @Expect(count, 150)
            }else if(topic == 'multi'){
                @Expect(count, 12)
            }else{
                @Expect(count >= 30, true)
            }
        }
        // 多相关样本必须真的有多个期望，否则「命中任一算对」的语义没被覆盖
        for(item in evalCases){
            if(item.topic == 'multi'){
                @Expect(item.expected.size >= 2, true)
            }
        }

        // 覆盖检查：每条语料都要被至少一条 query 引用。
        // 只加文档不加 query，指标不会下降——覆盖率却会静默漏掉一批主题。
        for(doc in docs){
            @Expect(referenced.contains(doc.id), true)
        }
    }

    /** 分层统计：主题内指标独立计算，负样本不计入 recall 分母 */
    @TestCase
    func testPerTopicAndNegativeStats(): Unit {
        let evalCases = ArrayList<EvalCase>([
            EvalCase('a1', ArrayList<String>(['x']), topic: 'alpha'),
            EvalCase('a2', ArrayList<String>(['x']), topic: 'alpha'),
            EvalCase('b1', ArrayList<String>(['y']), topic: 'beta'),
            EvalCase('n1', ArrayList<String>(), topic: 'negative')
        ].toArray())
        // alpha 全中第 1；beta 排第 2；负样本返回空 → 通过
        let search = { query: String, _: Int64 =>
            if(query == 'b1'){
                ArrayList<String>(['z', 'y'])
            }else if(query == 'n1'){
                ArrayList<String>()
            }else{
                ArrayList<String>(['x'])
            }
        }
        let report = RetrievalEval.evaluate(evalCases, search, topK: 5)
        @Expect(report.total, 3)                 // 负样本不进分母
        @Expect(report.negativeTotal, 1)
        @Expect(report.negativeRate(), 1.0f64)
        @Expect(report.topics.size, 2)

        var alpha: ?TopicStat = None
        var beta: ?TopicStat = None
        for(item in report.topics){
            if(item.topic == 'alpha'){
                alpha = Some(item)
            }
            if(item.topic == 'beta'){
                beta = Some(item)
            }
        }
        @Expect(alpha.getOrThrow().recallAt1(), 1.0f64)
        @Expect(beta.getOrThrow().recallAt1(), 0.0f64)
        @Expect(beta.getOrThrow().mrr(), 0.5f64)
        // 报告里最差的主题排在前面
        @Expect(report.render('分层').contains('beta'), true)
    }

    /**
     * 数据集「可检索」且分层有效：字符重合打分器在模板化样本上很高、在难样本上明显更低。
     *
     * 前半挡**数据集退化**（query 与期望文档对不上、改了 id 忘改 query）；
     * 后半挡**难样本失效**（如果难样本跟模板化一样容易，它就失去了区分模型的意义）。
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

        let templated = ArrayList<EvalCase>()
        let hard = ArrayList<EvalCase>()
        for(item in evalCases){
            if(item.isNegative()){
                continue
            }
            // 多相关样本单列：它的期望是一个集合，字符重合的表现与单期望不可比
            if(item.topic == 'hard'){
                hard.add(item)
            }else if(item.topic != 'multi'){
                templated.add(item)
            }
        }

        let easy = RetrievalEval.evaluate(templated, search, topK: 5)
        let tough = RetrievalEval.evaluate(hard, search, topK: 5)

        // 模板化样本：字符重合就该几乎全中；掉下来说明数据集本身出了问题
        @Expect(easy.recallAt1() >= 0.9f64, true)
        @Expect(easy.recallAtK() >= 0.95f64, true)
        // 难样本：字符重合只应该勉强命中——实测 recall@1 约 20%、recall@5 约 50%
        @Expect(tough.recallAt1() <= 0.5f64, true)
        @Expect(tough.recallAtK() <= 0.75f64, true)
        // 两组必须拉开差距，否则「难样本」名不副实
        @Expect(tough.recallAt1() < easy.recallAt1(), true)
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

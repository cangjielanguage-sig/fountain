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
import std.env.getVariable
import std.fs.*
import std.io.*
import std.math.log

/** 评测语料里的一条文档 */
public class EvalDoc {
    public let id: String
    public let title: String
    public let content: String

    public init(id: String, title: String, content: String) {
        this.id = id
        this.title = title
        this.content = content
    }
}

/**
 * 一条评测 query。
 *
 * - `expected` 为空表示**负样本**：期望检索不到任何文档（用来校验 `minScore` 阈值）；
 * - `topic` 用于分层统计——全局指标会把「某个主题全错」平均掉。
 */
public class EvalCase {
    public let query: String
    public let expected: ArrayList<String>
    public let topic: String

    public init(query: String, expected: ArrayList<String>, topic!: String = '') {
        this.query = query
        this.expected = expected
        this.topic = topic
    }

    public func isNegative(): Bool {
        expected.isEmpty()
    }
}

/** 单个主题的指标 */
public class TopicStat {
    public let topic: String
    public let total: Int64
    public let hitAt1: Int64
    public let hitAtK: Int64
    public let reciprocalSum: Float64
    public let ndcgSum: Float64

    public init(topic: String, total: Int64, hitAt1: Int64, hitAtK: Int64,
                reciprocalSum: Float64, ndcgSum: Float64) {
        this.topic = topic
        this.total = total
        this.hitAt1 = hitAt1
        this.hitAtK = hitAtK
        this.reciprocalSum = reciprocalSum
        this.ndcgSum = ndcgSum
    }

    /** nDCG@k（二值相关）：位置越靠前分越高，多相关样本也能反映「漏了几个」 */
    public func ndcg(): Float64 {
        if(total <= 0){
            return 0.0f64
        }
        ndcgSum / Float64(total)
    }

    public func recallAt1(): Float64 {
        if(total <= 0){
            return 0.0f64
        }
        Float64(hitAt1) / Float64(total)
    }

    public func recallAtK(): Float64 {
        if(total <= 0){
            return 0.0f64
        }
        Float64(hitAtK) / Float64(total)
    }

    public func mrr(): Float64 {
        if(total <= 0){
            return 0.0f64
        }
        reciprocalSum / Float64(total)
    }
}

/** 一轮评测的结果：全局指标 + 负样本通过率 + 按主题分层 */
public class EvalReport {
    public let total: Int64
    public let hitAt1: Int64
    public let hitAtK: Int64
    public let reciprocalSum: Float64
    public let ndcgSum: Float64
    public let topK: Int64
    public let misses: ArrayList<String>
    public let negativeTotal: Int64
    public let negativePassed: Int64
    public let topics: ArrayList<TopicStat>

    public init(total: Int64, hitAt1: Int64, hitAtK: Int64, reciprocalSum: Float64,
                ndcgSum: Float64, topK: Int64, misses: ArrayList<String>,
                negativeTotal: Int64, negativePassed: Int64,
                topics: ArrayList<TopicStat>) {
        this.total = total
        this.hitAt1 = hitAt1
        this.hitAtK = hitAtK
        this.reciprocalSum = reciprocalSum
        this.ndcgSum = ndcgSum
        this.topK = topK
        this.misses = misses
        this.negativeTotal = negativeTotal
        this.negativePassed = negativePassed
        this.topics = topics
    }

    /**
     * nDCG@k（二值相关）：与 recall 的区别是**位置敏感**，且会惩罚「多相关只命中一个」。
     *
     * 单相关样本里它等于 `1/log2(rank+1)`；多相关样本里理想排序能给到 1.0。
     */
    public func ndcg(): Float64 {
        if(total <= 0){
            return 0.0f64
        }
        ndcgSum / Float64(total)
    }

    public func recallAt1(): Float64 {
        if(total <= 0){
            return 0.0f64
        }
        Float64(hitAt1) / Float64(total)
    }

    public func recallAtK(): Float64 {
        if(total <= 0){
            return 0.0f64
        }
        Float64(hitAtK) / Float64(total)
    }

    public func mrr(): Float64 {
        if(total <= 0){
            return 0.0f64
        }
        reciprocalSum / Float64(total)
    }

    /** 负样本通过率：检索结果为空才算通过 */
    public func negativeRate(): Float64 {
        if(negativeTotal <= 0){
            return 0.0f64
        }
        Float64(negativePassed) / Float64(negativeTotal)
    }

    /**
     * 可直接打印的报告：全局 → 负样本 → 按主题（recall@1 升序，最差的排前面）。
     *
     * 主题排序是刻意的：全局 85% 可能掩盖「某个主题 0%」，先看垫底的主题。
     */
    public func render(label: String): String {
        var text = '== ${label} ==\n'
        text += 'cases=${total} topK=${topK}\n'
        text += 'recall@1=${percent(recallAt1())} recall@${topK}=${percent(recallAtK())} '
        text += 'mrr=${percent(mrr())} ndcg@${topK}=${percent(ndcg())}\n'
        if(negativeTotal > 0){
            text += 'negatives=${negativeTotal} pass=${percent(negativeRate())}\n'
        }
        if(!topics.isEmpty()){
            text += 'by topic (worst first):\n'
            let sorted = ArrayList<TopicStat>()
            for(item in topics){
                sorted.add(item)
            }
            for(left in 0..sorted.size){
                var lowest = left
                for(right in left + 1..sorted.size){
                    if(sorted[right].recallAt1() < sorted[lowest].recallAt1()){
                        lowest = right
                    }
                }
                if(lowest != left){
                    let temp = sorted[left]
                    sorted[left] = sorted[lowest]
                    sorted[lowest] = temp
                }
            }
            for(item in sorted){
                text += '  ${padRight(item.topic, 10)} n=${item.total} '
                text += 'r@1=${percent(item.recallAt1())} r@${topK}=${percent(item.recallAtK())} '
                text += 'mrr=${percent(item.mrr())} ndcg=${percent(item.ndcg())}\n'
            }
        }
        if(!misses.isEmpty()){
            text += 'misses(${misses.size}):\n'
            for(query in misses){
                text += '  - ${query}\n'
            }
        }
        text
    }

    private static func percent(value: Float64): String {
        '${Int64(value * 10000.0f64) / 100}.${Int64(value * 10000.0f64) % 100}%'
    }

    private static func padRight(text: String, width: Int64): String {
        var padded = text
        while(Int64(padded.size) < width){
            padded += ' '
        }
        padded
    }
}

/**
 * 检索质量评测骨架：读 TSV 语料与 query 集，跑一个检索函数，算 recall / MRR / 分层。
 *
 * 刻意不内置真实的 embedding 调用——真实模型依赖网络与版本，跑 CI 既慢又不稳定。
 * 用法是把「怎么检索」作为函数传进来：单元测试传假编码器的检索器（确定），
 * 离线评测传 `SkillCatalog.search` 或向量库检索（真实模型）。
 */
public class RetrievalEval {
    private init() {
    }

    /** 语料目录：默认 `./eval`，可用 `fllm_evalDir` 覆盖 */
    public static func defaultDir(): String {
        match(getVariable('fllm_evalDir')){
            case Some(value) => value
            case None => './eval'
        }
    }

    /** 读 `id \t 标题 \t 正文`；跳过空行与 `#` 注释 */
    public static func readCorpus(path: String): ArrayList<EvalDoc> {
        let docs = ArrayList<EvalDoc>()
        for(line in linesOf(path)){
            let fields = line.split('\t')
            if(fields.size < 2){
                continue
            }
            let content = if(fields.size >= 3){ fields[2] }else{ '' }
            docs.add(EvalDoc(fields[0], fields[1], content))
        }
        docs
    }

    /** 读 `query \t 期望id[,期望id] \t 主题`；期望列为 `-` 表示负样本 */
    public static func readCases(path: String): ArrayList<EvalCase> {
        let cases = ArrayList<EvalCase>()
        for(line in linesOf(path)){
            let fields = line.split('\t')
            if(fields.size < 2){
                continue
            }
            let topic = if(fields.size >= 3){ fields[2].trimAscii() }else{ '' }
            let expected = ArrayList<String>()
            let raw = fields[1].trimAscii()
            if(raw != '-'){
                for(item in raw.split(',')){
                    let id = item.trimAscii()
                    if(!id.isEmpty()){
                        expected.add(id)
                    }
                }
            }
            if(expected.isEmpty() && raw != '-'){
                // 既不是负样本、又没写期望：数据写坏了，直接跳过而不是当成负样本
                continue
            }
            cases.add(EvalCase(fields[0], expected, topic: topic))
        }
        cases
    }

    /**
     * 跑一轮评测：`search(query, topK)` 返回按相关度降序的 id 列表。
     *
     * MRR 取「期望文档中排名最靠前的那一个」的倒数排名；未命中记入 `misses`。
     * 负样本单独统计：返回空列表才算通过，不计入 recall 分母。
     */
    public static func evaluate(cases: ArrayList<EvalCase>,
                                search: (String, Int64) -> ArrayList<String>,
                                topK!: Int64 = 5): EvalReport {
        var hitAt1: Int64 = 0
        var hitAtK: Int64 = 0
        var reciprocal: Float64 = 0.0f64
        var ndcgTotal: Float64 = 0.0f64
        var negativeTotal: Int64 = 0
        var negativePassed: Int64 = 0
        let misses = ArrayList<String>()
        let statMap = HashMap<String, ArrayList<Int64>>()   // topic → [total, hit1, hitK]
        let reciprocalMap = HashMap<String, Float64>()
        let ndcgMap = HashMap<String, Float64>()

        for(item in cases){
            let ranked = search(item.query, topK)
            if(item.isNegative()){
                negativeTotal++
                if(ranked.isEmpty()){
                    negativePassed++
                }
                continue
            }
            let topic = if(item.topic.isEmpty()){ 'default' }else{ item.topic }
            let stat = match(statMap.get(topic)){
                case Some(value) => value
                case None => ArrayList<Int64>([0, 0, 0])
            }
            stat[0] = stat[0] + 1

            var rank: Int64 = 0
            for(index in 0..ranked.size){
                var matched = false
                for(expected in item.expected){
                    if(ranked[index] == expected){
                        matched = true
                    }
                }
                if(matched){
                    rank = index + 1
                    break
                }
            }
            if(rank == 1){
                hitAt1++
                stat[1] = stat[1] + 1
            }
            if(rank >= 1){
                hitAtK++
                stat[2] = stat[2] + 1
                reciprocal += 1.0f64 / Float64(rank)
                reciprocalMap[topic] = (reciprocalMap.get(topic) ?? 0.0f64) + 1.0f64 / Float64(rank)
            }else{
                misses.add(item.query)
            }
            // nDCG@k：二值相关，位置越靠前增益越大；多相关样本按理想排序归一
            let ndcg = ndcgOf(ranked, item.expected, topK)
            ndcgTotal += ndcg
            ndcgMap[topic] = (ndcgMap.get(topic) ?? 0.0f64) + ndcg
            statMap[topic] = stat
        }

        let topics = ArrayList<TopicStat>()
        for((topic, stat) in statMap){
            topics.add(TopicStat(topic, stat[0], stat[1], stat[2],
                                 reciprocalMap.get(topic) ?? 0.0f64,
                                 ndcgMap.get(topic) ?? 0.0f64))
        }
        // 正样本总数 = 命中的 + 未命中的（负样本不计入分母）
        let positiveTotal = hitAtK + Int64(misses.size)
        EvalReport(positiveTotal, hitAt1, hitAtK, reciprocal, ndcgTotal,
                   topK, misses, negativeTotal, negativePassed, topics)
    }

    /**
     * nDCG@k（二值相关）。
     *
     * `DCG = Σ gain_i / log2(i+1)`，`IDCG` 是「期望文档全排在最前」时的值，
     * 因此单相关样本等价于 `1/log2(rank+1)`，多相关样本还能反映「只命中其中一个」。
     */
    private static func ndcgOf(ranked: ArrayList<String>, expected: ArrayList<String>,
                               topK: Int64): Float64 {
        var dcg = 0.0f64
        let limit = if(Int64(ranked.size) < topK){ Int64(ranked.size) }else{ topK }
        for(index in 0..limit){
            var gain = 0.0f64
            for(wanted in expected){
                if(ranked[index] == wanted){
                    gain = 1.0f64
                }
            }
            if(gain > 0.0f64){
                dcg += gain / discount(index + 1)
            }
        }
        var ideal = 0.0f64
        let idealCount = if(Int64(expected.size) < topK){ Int64(expected.size) }else{ topK }
        for(index in 0..idealCount){
            ideal += 1.0f64 / discount(index + 1)
        }
        if(ideal <= 0.0f64){
            return 0.0f64
        }
        dcg / ideal
    }

    /** `1 / log2(rank + 1)`，rank 从 1 开始 */
    private static func discount(rank: Int64): Float64 {
        log(Float64(rank) + 1.0f64) / log(2.0f64)
    }

    private static func linesOf(path: String): ArrayList<String> {
        let result = ArrayList<String>()
        let file = File(path, OpenMode.Read)
        let text = StringReader(file).readToEnd()
        file.close()
        for(line in text.split('\n')){
            let trimmed = line.trimAscii()
            if(trimmed.isEmpty() || trimmed.startsWith('#')){
                continue
            }
            result.add(trimmed)
        }
        result
    }
}

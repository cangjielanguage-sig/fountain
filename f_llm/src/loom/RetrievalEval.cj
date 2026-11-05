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

/** 一条评测 query 与它期望命中的文档（多个即「命中任一算对」） */
public class EvalCase {
    public let query: String
    public let expected: ArrayList<String>

    public init(query: String, expected: ArrayList<String>) {
        this.query = query
        this.expected = expected
    }
}

/** 一轮评测的结果：recall@1 / recall@k / MRR + 未命中清单 */
public class EvalReport {
    public let total: Int64
    public let hitAt1: Int64
    public let hitAtK: Int64
    public let reciprocalSum: Float64
    public let topK: Int64
    public let misses: ArrayList<String>

    public init(total: Int64, hitAt1: Int64, hitAtK: Int64, reciprocalSum: Float64,
                topK: Int64, misses: ArrayList<String>) {
        this.total = total
        this.hitAt1 = hitAt1
        this.hitAtK = hitAtK
        this.reciprocalSum = reciprocalSum
        this.topK = topK
        this.misses = misses
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

    /** 可直接打印的报告 */
    public func render(label: String): String {
        var text = '== ${label} ==\n'
        text += 'cases=${total} topK=${topK}\n'
        text += 'recall@1=${percent(recallAt1())} recall@${topK}=${percent(recallAtK())} '
        text += 'mrr=${percent(mrr())}\n'
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
}

/**
 * 检索质量评测骨架：读 TSV 语料与 query 集，跑一个检索函数，算 recall / MRR。
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

    /** 读 `query \t 期望id[,期望id]` */
    public static func readCases(path: String): ArrayList<EvalCase> {
        let cases = ArrayList<EvalCase>()
        for(line in linesOf(path)){
            let fields = line.split('\t')
            if(fields.size < 2){
                continue
            }
            let expected = ArrayList<String>()
            for(item in fields[1].split(',')){
                let id = item.trimAscii()
                if(!id.isEmpty()){
                    expected.add(id)
                }
            }
            if(!expected.isEmpty()){
                cases.add(EvalCase(fields[0], expected))
            }
        }
        cases
    }

    /**
     * 跑一轮评测：`search(query, topK)` 返回按相关度降序的 id 列表。
     *
     * MRR 取「期望文档中排名最靠前的那一个」的倒数排名；未命中记入 `misses`。
     */
    public static func evaluate(cases: ArrayList<EvalCase>,
                                search: (String, Int64) -> ArrayList<String>,
                                topK!: Int64 = 5): EvalReport {
        var hitAt1: Int64 = 0
        var hitAtK: Int64 = 0
        var reciprocal: Float64 = 0.0f64
        let misses = ArrayList<String>()
        for(item in cases){
            let ranked = search(item.query, topK)
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
            }
            if(rank >= 1){
                hitAtK++
                reciprocal += 1.0f64 / Float64(rank)
            }else{
                misses.add(item.query)
            }
        }
        EvalReport(Int64(cases.size), hitAt1, hitAtK, reciprocal, topK, misses)
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

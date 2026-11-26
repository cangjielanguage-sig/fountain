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

import std.collection.*

/**
 * 知识检索的打分与排序（P0）：**词面命中数**排序，不含向量语义。
 *
 * 各后端只负责「按首个词召回候选块」，打分与排序都走这里，
 * 保证 PG / MySQL / 内存三种实现的排序口径完全一致。
 */
public class KnowledgeSearch {
    private init() {
    }

    /** 查询按空白切词、去空、去重（保序） */
    public static func terms(text: String): ArrayList<String> {
        let result = ArrayList<String>()
        for(part in text.split(' ')){
            let term = part.trimAscii()
            if(term.isEmpty() || contains(result, term)){
                continue
            }
            result.add(term)
        }
        result
    }

    /** 不可重叠计数（`aa` in `aaa` = 1） */
    public static func occurrences(text: String, term: String): Int64 {
        if(term.isEmpty()){
            return 0
        }
        var count: Int64 = 0
        var from: Int64 = 0
        while(true){
            match(text.indexOf(term, from)){
                case Some(index) =>
                    count++
                    from = index + Int64(term.size)
                case None => break
            }
        }
        count
    }

    /** 所有词的出现次数之和；0 表示无关 */
    public static func score(content: String, terms: ArrayList<String>): Float64 {
        var total: Int64 = 0
        for(term in terms){
            total += occurrences(content, term)
        }
        Float64(total)
    }

    /** 按分数降序、docId/seq 升序（保证跨后端一致），截断到 limit */
    public static func rank(hits: ArrayList<KnowledgeHit>, limit: Int64): ArrayList<KnowledgeHit> {
        let sorted = ArrayList<KnowledgeHit>()
        sorted.add(all: hits)
        // 候选通常 ≤ 200，插入排序足够且稳定
        for(index in 1..sorted.size){
            let current = sorted[index]
            var position = index - 1
            while(position >= 0 && before(current, sorted[position])){
                sorted[position + 1] = sorted[position]
                position--
            }
            sorted[position + 1] = current
        }
        let limit2 = if(limit <= 0){ 0 }else{ limit }
        let result = ArrayList<KnowledgeHit>()
        for(index in 0..sorted.size){
            if(Int64(index) >= limit2){
                break
            }
            result.add(sorted[index])
        }
        result
    }

    /** current 应排在 other 之前 */
    private static func before(current: KnowledgeHit, other: KnowledgeHit): Bool {
        if(current.score != other.score){
            return current.score > other.score
        }
        if(current.docId != other.docId){
            return current.docId < other.docId
        }
        current.seq < other.seq
    }

    private static func contains(items: ArrayList<String>, value: String): Bool {
        for(item in items){
            if(item == value){
                return true
            }
        }
        false
    }
}

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
import std.math.*

import fountain::f_llm.store.*

/** 一条待归属的经验 */
public class ExperienceItem {
    public let id: Int64
    public let content: String

    public init(id: Int64, content: String) {
        this.id = id
        this.content = content
    }
}

/** 归到某个已有技能的一组经验 */
public class SkillAssignment {
    public let skillTitle: String
    public let experiences: ArrayList<ExperienceItem>

    public init(skillTitle: String, experiences: ArrayList<ExperienceItem>) {
        this.skillTitle = skillTitle
        this.experiences = experiences
    }
}

/** 归不到任何技能、但彼此相近的一组经验：可能该沉淀成新技能 */
public class SkillCandidate {
    public let experiences: ArrayList<ExperienceItem>
    public let score: Float64

    public init(experiences: ArrayList<ExperienceItem>, score: Float64) {
        this.experiences = experiences
        this.score = score
    }
}

public class SkillMatchResult {
    public let assignments: ArrayList<SkillAssignment>
    public let candidates: ArrayList<SkillCandidate>

    public init(assignments: ArrayList<SkillAssignment>,
                candidates: ArrayList<SkillCandidate>) {
        this.assignments = assignments
        this.candidates = candidates
    }

    public prop assignedCount: Int64 {
        get() {
            var total: Int64 = 0
            for(item in assignments){
                total += Int64(item.experiences.size)
            }
            total
        }
    }
}

/**
 * 经验归属发现：把一批**未绑定技能**的经验分到「已有技能」或「新技能候选」。
 *
 * 为什么不在写经验时就绑定技能：写入时往往还不知道这条经验属于谁，而且技能可能
 * 尚不存在（最有价值的正是「这堆经验该沉淀成新技能」）。所以绑定留在这一层做。
 *
 * 两种相似度：
 * - 向量（装了 embedder）：余弦相似度，技能侧用 `标题 + 正文` 编码；
 * - 关键词（无 embedder 或编码失败）：字符/词面覆盖度，阈值更高。
 */
public class SkillMatcher {
    private init() {
    }

    /**
     * @param experiences 待归属经验（建议只传 `kind=experience` 的成功经验）
     * @param skills 现有技能
     * @param threshold 归到已有技能的相似度阈值
     * @param minCluster 新技能候选的最少条数
     */
    public static func assign(experiences: ArrayList<ExperienceItem>,
                             skills: ArrayList<Skill>,
                             embedder!: ?(String) -> Array<Float64> = None,
                             threshold!: Float64 = 0.75,
                             minCluster!: Int64 = 3): SkillMatchResult {
        let assignments = ArrayList<SkillAssignment>()
        let candidates = ArrayList<SkillCandidate>()
        if(experiences.isEmpty()){
            return SkillMatchResult(assignments, candidates)
        }

        // 技能侧先编码（技能少，成本可忽略）；编码失败的技能退出比较
        let skillVectors = HashMap<String, Array<Float64>>()
        var usable = ArrayList<Skill>()
        match(embedder){
            case Some(encode) =>
                for(skill in skills){
                    match(encodeSafely(encode, '${skill.title}\n${skill.details}')){
                        case Some(vector) =>
                            skillVectors[skill.title] = vector
                            usable.add(skill)
                        case None => ()
                    }
                }
            case None => ()
        }

        // 每条经验先试已有技能
        let grouped = HashMap<String, ArrayList<ExperienceItem>>()
        let leftovers = ArrayList<ExperienceItem>()
        for(item in experiences){
            var bestTitle = ''
            var bestScore = 0.0f64
            for(skill in usable){
                let vector = skillVectors.get(skill.title).getOrThrow()
                let score = match(encodeSafely(embedderValue(embedder), item.content)){
                    case Some(value) => cosine(value, vector)
                    case None => 0.0f64
                }
                if(score > bestScore){
                    bestScore = score
                    bestTitle = skill.title
                }
            }
            if(bestTitle.isEmpty()){
                // 没有可用向量：退回关键词，对全部技能逐一比对
                for(skill in skills){
                    let score = keywordSimilarity(item.content, '${skill.title} ${skill.details}')
                    if(score > bestScore){
                        bestScore = score
                        bestTitle = skill.title
                    }
                }
            }
            if(!bestTitle.isEmpty() && bestScore >= threshold){
                let bucket = grouped.get(bestTitle) ?? ArrayList<ExperienceItem>()
                bucket.add(item)
                grouped[bestTitle] = bucket
            }else{
                leftovers.add(item)
            }
        }

        for(skill in skills){
            match(grouped.get(skill.title)){
                case Some(bucket) => assignments.add(SkillAssignment(skill.title, bucket))
                case None => ()
            }
        }

        // 剩下的彼此聚类：与簇首足够像就并进去，否则自己当簇首
        let leaders = ArrayList<ExperienceItem>()
        let clusters = ArrayList<ArrayList<ExperienceItem>>()
        for(item in leftovers){
            var joined = false
            for(index in 0..leaders.size){
                let score = similarity(embedder, item.content, leaders[index].content)
                if(score >= threshold){
                    clusters[index].add(item)
                    joined = true
                    break
                }
            }
            if(!joined){
                leaders.add(item)
                let bucket = ArrayList<ExperienceItem>()
                bucket.add(item)
                clusters.add(bucket)
            }
        }
        for(index in 0..clusters.size){
            let bucket = clusters[index]
            if(Int64(bucket.size) >= minCluster){
                candidates.add(SkillCandidate(bucket,
                    similarity(embedder, bucket[0].content, bucket[bucket.size - 1].content)))
            }
        }
        SkillMatchResult(assignments, candidates)
    }

    private static func embedderValue(value: ?(String) -> Array<Float64>): (String) -> Array<Float64> {
        match(value){
            case Some(fn) => fn
            case None => { _ => Array<Float64>() }
        }
    }

    private static func encodeSafely(encode: (String) -> Array<Float64>,
                                     text: String): ?Array<Float64> {
        try{
            let vector = encode(text)
            if(vector.isEmpty()){
                return None
            }
            Some(vector)
        }catch(error: Exception){
            None
        }
    }

    /** 两段文本的相似度：有编码器就走余弦，否则词面 */
    private static func similarity(embedder: ?(String) -> Array<Float64>,
                                   left: String, right: String): Float64 {
        match(embedder){
            case Some(encode) =>
                let a = encodeSafely(encode, left)
                let b = encodeSafely(encode, right)
                match((a, b)){
                    case (Some(x), Some(y)) => cosine(x, y)
                    case _ => keywordSimilarity(left, right)
                }
            case None => keywordSimilarity(left, right)
        }
    }

    private static func cosine(left: Array<Float64>, right: Array<Float64>): Float64 {
        let size = if(left.size < right.size){ left.size }else{ right.size }
        if(size == 0){
            return 0.0f64
        }
        var dot = 0.0f64
        var leftNorm = 0.0f64
        var rightNorm = 0.0f64
        for(index in 0..size){
            dot += left[index] * right[index]
            leftNorm += left[index] * left[index]
            rightNorm += right[index] * right[index]
        }
        if(leftNorm <= 0.0f64 || rightNorm <= 0.0f64){
            return 0.0f64
        }
        dot / (sqrt(leftNorm) * sqrt(rightNorm))
    }

    /** 词面相似度：双向字符覆盖，取较高者 */
    private static func keywordSimilarity(left: String, right: String): Float64 {
        let forward = runeCoverage(left, right)
        let backward = runeCoverage(right, left)
        if(forward > backward){
            forward
        }else{
            backward
        }
    }

    /** `source` 里有多少字出现在 `target` 中 */
    private static func runeCoverage(source: String, target: String): Float64 {
        var total: Int64 = 0
        var hits: Int64 = 0
        let seen = HashSet<Rune>()
        for(rune in source.runes()){
            if(rune == r' ' || rune == r'\n'){
                continue
            }
            if(seen.contains(rune)){
                continue
            }
            seen.add(rune)
            total++
            if(target.contains(rune.toString())){
                hits++
            }
        }
        if(total == 0){
            return 0.0f64
        }
        Float64(hits) / Float64(total)
    }
}

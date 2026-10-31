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
package fountain::f_hydra

/** 向量数学：余弦相似度（暴力检索、k-means 分配、候选打分共用） */
public class VectorMath {
    private init() {
    }

    /** 范围 [-1, 1]；长度不一致或零向量返回 0 */
    public static func cosine(a: Array<Float64>, b: Array<Float64>): Float64 {
        if(a.size != b.size || a.isEmpty()){
            return 0.0f64
        }
        var dot: Float64 = 0.0f64
        var normA: Float64 = 0.0f64
        var normB: Float64 = 0.0f64
        for(index in 0..a.size){
            dot += a[index] * b[index]
            normA += a[index] * a[index]
            normB += b[index] * b[index]
        }
        if(normA <= 0.0f64 || normB <= 0.0f64){
            return 0.0f64
        }
        dot / (sqrt(normA) * sqrt(normB))
    }

    private static func sqrt(value: Float64): Float64 {
        if(value <= 0.0f64){
            return 0.0f64
        }
        var guess = value
        for(_ in 0..30){
            guess = (guess + value / guess) / 2.0f64
        }
        guess
    }
}

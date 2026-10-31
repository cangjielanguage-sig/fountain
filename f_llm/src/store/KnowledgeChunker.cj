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
 * 知识文档切块（P0）。
 *
 * 按**字符数**滑窗切分：`maxChars` 为窗口大小，`overlap` 为相邻窗口重叠，
 * 用于避免关键词正好落在切分边界。纯函数，便于单测；编码无关（不按字节）。
 */
public class KnowledgeChunker {
    public static const DEFAULT_MAX_CHARS = 400
    public static const DEFAULT_OVERLAP = 50

    private init() {
    }

    public static func split(content: String, maxChars!: Int64 = DEFAULT_MAX_CHARS,
                             overlap!: Int64 = DEFAULT_OVERLAP): ArrayList<String> {
        if(maxChars <= 0){
            throw IllegalArgumentException('maxChars must be positive, got ${maxChars}')
        }
        if(overlap < 0 || overlap >= maxChars){
            throw IllegalArgumentException(
                'overlap must be in [0, maxChars), got ${overlap} (maxChars=${maxChars})')
        }
        let chunks = ArrayList<String>()
        if(content.isEmpty()){
            return chunks
        }
        let step = maxChars - overlap
        var start: Int64 = 0
        while(start < Int64(content.size)){
            let end = minOf(Int64(content.size), start + maxChars)
            let piece = content[start..end]
            if(!piece.isEmpty()){
                chunks.add(piece)
            }
            if(end >= Int64(content.size)){
                break
            }
            start += step
        }
        chunks
    }

    private static func minOf(a: Int64, b: Int64): Int64 {
        if(a < b){
            a
        }else{
            b
        }
    }
}

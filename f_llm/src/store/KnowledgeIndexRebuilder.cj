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
 * 知识块向量重建（运维工具）。
 *
 * 换 Embedder（模型/维度）或改切块参数后，库里旧块的向量会与新查询不匹配。
 * 本工具按 docId 分页把文档重新 `upsert` 一遍：重新切块、重新向量化、覆盖旧块。
 *
 * 注意：维度变化时先改表结构（PG `vector(n)` / MySQL `MYVECTOR(dim=n)`），否则写入会报错。
 */
public class KnowledgeIndexRebuilder {
    private init() {
    }

    /** 重建指定文档，返回实际重建篇数 */
    public static func rebuild(store: KnowledgeStore, docIds: ArrayList<String>): Int64 {
        var rebuilt: Int64 = 0
        for(docId in docIds){
            match(store.get(docId)){
                case Some(doc) =>
                    store.upsert(doc)
                    rebuilt++
                case None => ()
            }
        }
        rebuilt
    }

    /** 全库重建：按 docId 分页，避免一次拉全表 */
    public static func rebuildAll(store: KnowledgeStore, batchSize!: Int64 = 100): Int64 {
        if(batchSize <= 0){
            throw IllegalArgumentException('batchSize must be positive, got ${batchSize}')
        }
        var offset: Int64 = 0
        var rebuilt: Int64 = 0
        while(true){
            let page = store.docIds(offset, batchSize)
            if(page.isEmpty()){
                break
            }
            rebuilt += rebuild(store, page)
            if(page.size < batchSize){
                break
            }
            offset += batchSize
        }
        rebuilt
    }
}

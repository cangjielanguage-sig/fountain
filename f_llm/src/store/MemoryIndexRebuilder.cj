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
 * 索引重建（运维工具）。
 *
 * sparse 倒排与 colbert 向量是「写入时的附加产物」：早期数据只写了 dense，
 * 或换过向量模型后维度/词表变化，都会让检索退化为 dense-only（结果标 `degraded`）。
 * 本工具按 `(userId, namespace)` 分页扫描既有记录，重算这两路并覆盖写。
 *
 * 只读 `content` / `title`，不改 dense 向量——换模型需要重算 dense 时用
 * [MemoryStore.add] 重新写入（`(user_id, namespace, title)` 唯一键会覆盖）。
 */
public class MemoryIndexRebuilder {
    private init() {
    }

    /**
     * @param repository 目标仓库（PG / MySQL 均可）
     * @param embedder   向量化实现
     * @param userId     要重建的用户
     * @param namespace  要重建的命名空间
     * @param batchSize  分页大小（默认 100）
     * @return 实际重建的记录条数
     */
    public static func rebuild(repository: MemoryRepository, embedder: Embedder,
                               userId: Int64, namespace: String,
                               batchSize!: Int64 = 100): Int64 {
        if(batchSize <= 0){
            throw IllegalArgumentException('batchSize must be positive, got ${batchSize}')
        }
        var offset: Int64 = 0
        var rebuilt: Int64 = 0
        while(true){
            let records = repository.list(userId, namespace, offset, batchSize)
            if(records.isEmpty()){
                break
            }
            for(record in records){
                repository.upsertSparse(record.id, record.userId, record.namespace,
                                        tokensOf(embedder, record.title, record.content))
                repository.upsertColbert(record.id,
                                         embedder.embedColbert(record.title),
                                         embedder.embedColbert(record.content))
                rebuilt++
            }
            offset += records.size
        }
        rebuilt
    }

    /** 与写入路径一致：标题 + 正文合并，同 token 取较大权重 */
    private static func tokensOf(embedder: Embedder, title: String,
                                 content: String): HashMap<Int64, Float64> {
        let tokens = HashMap<Int64, Float64>()
        for((token, weight) in embedder.tokenize(title)){
            tokens[token] = weight
        }
        for((token, weight) in embedder.tokenize(content)){
            match(tokens.get(token)){
                case Some(existing) =>
                    if(weight > existing){
                        tokens[token] = weight
                    }
                case None => tokens[token] = weight
            }
        }
        tokens
    }
}

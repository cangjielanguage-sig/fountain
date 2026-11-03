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
 * 向量化入口：生产环境包 BGE-M3，测试注入假实现。
 *
 * 单独抽接口的原因：`add` 的行为（两次向量化、失败拒绝写入）不该依赖 HTTP。
 */
public interface Embedder {
    func embed(text: String): Array<Float64>
    /** 多头向量：每个 token 一个 1024 维向量；本变更只用于重排 */
    func embedColbert(text: String): Array<Array<Float64>>
    /** 稀疏向量：BGE-M3 token id → 权重；sparse 倒排的写入与召回都依赖它 */
    func tokenize(text: String): HashMap<Int64, Float64>
}

/**
 * 记忆持久化 SPI：SQL 细节（upsert、唯一键、事务）由它承担。
 *
 * 唯一键是 `(user_id, namespace, title)`：同键写入覆盖，返回既有 id。
 */
public interface MemoryRepository {
    func upsert(write: MemoryWrite, titleVector: Array<Float64>, contentVector: Array<Float64>): Int64

    /**
     * dense 召回：只负责「按相似度取 limit 条」，不乘 kind 权重、不排序截断。
     * 权重与 topK 在 store 层做，保证不同后端打分口径一致。
     */
    func searchDense(query: MemoryQuery, vector: Array<Float64>, limit: Int64): ArrayList<MemoryHit>

    /** sparse 召回：按 token 命中累加权重；没有倒排数据时返回空列表（由 store 标 degraded） */
    func searchSparse(query: MemoryQuery, tokens: HashMap<Int64, Float64>, limit: Int64): ArrayList<MemoryHit>

    /** 覆盖写稀疏倒排：先删旧 token，再写新 token */
    func upsertSparse(memoryId: Int64, userId: Int64, namespace: String, tokens: HashMap<Int64, Float64>): Unit

    /** 覆盖写 colbert 多头向量；空数组表示没有 */
    func upsertColbert(memoryId: Int64, titleVectors: Array<Array<Float64>>,
                       contentVectors: Array<Array<Float64>>): Unit

    /** 取某条记忆的 colbert 向量；没有则返回 None（重排时跳过） */
    func colbert(recordId: Int64): ?ColbertVectors

    func get(userId: Int64, id: Int64): ?MemoryRecord

    func list(userId: Int64, namespace: String, offset: Int64, limit: Int64): ArrayList<MemoryRecord>

    func remove(userId: Int64, id: Int64): Bool

    /**
     * 按 `kind` 分页。
     *
     * 默认实现是近似的（取一页再过滤）：仓储实现应覆盖成 SQL 条件或全量扫描，
     * 否则 `limit` 很小时会漏掉目标记录。
     */
    func listByKind(userId: Int64, namespace: String, kind: String,
                    offset: Int64, limit: Int64): ArrayList<MemoryRecord> {
        let page = list(userId, namespace, offset, limit)
        let matched = ArrayList<MemoryRecord>()
        for(record in page){
            if(record.kind == kind){
                matched.add(record)
            }
        }
        matched
    }
}

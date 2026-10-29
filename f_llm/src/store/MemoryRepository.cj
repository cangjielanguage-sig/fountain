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

import std.collection.ArrayList

/**
 * 向量化入口：生产环境包 BGE-M3，测试注入假实现。
 *
 * 单独抽接口的原因：`add` 的行为（两次向量化、失败拒绝写入）不该依赖 HTTP。
 */
public interface Embedder {
    func embed(text: String): Array<Float64>
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
    func searchSparse(query: MemoryQuery, limit: Int64): ArrayList<MemoryHit>
}

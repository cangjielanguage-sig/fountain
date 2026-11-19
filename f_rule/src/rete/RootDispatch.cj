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
package fountain::f_rule.rete

import std.collection.{ArrayList, HashMap}
import fountain::f_rule.fact.{Fact, FactHandle, ValueKey}

/**
 * 根节点的按值分发表（`doc/04-rete-network.md` §3）。
 *
 * 同一类型下可以有很多"首约束为等值"的 alpha 链头。逐个调用测试闭包的成本是
 * `O(链头数)` 每条事实，而等值约束天然可以按 `(字段, 值)` 建哈希桶：插入时只
 * 计算一次字段值，命中桶内的链头才继续传播，其余链头完全跳过。
 *
 * 只收纳 `parentKey == ""`、非否定、右值为常量且算子为 `Eq` 的链头；其余链头仍
 * 走逐条测试，两条路径的匹配语义完全一致（桶成员等价于该约束判定为 `True`）。
 */
class RootDispatch {
    /** 需要逐条测试的链头（范围、否定、右字段、非常量等）。 */
    let unindexed: ArrayList<AlphaNode>
    /** `字段 → 值 → 链头`；同一字段的多个等值链头共享一次值计算。 */
    let indexed: HashMap<String, HashMap<ValueKey, ArrayList<AlphaNode>>>

    RootDispatch() {
        this.unindexed = ArrayList<AlphaNode>()
        this.indexed = HashMap<String, HashMap<ValueKey, ArrayList<AlphaNode>>>()
    }

    /** 登记链头；返回 `true` 表示已进入按值索引。 */
    func add(node: AlphaNode): Bool {
        let signature = node.signature
        if (signature.parentKey != "" || signature.negated || signature.rightField.isSome()) {
            unindexed.add(node)
            return false
        }
        if (signature.opName != "Eq") {
            unindexed.add(node)
            return false
        }
        let value = match (signature.value) {
            case Some(found) => found
            case None =>
                unindexed.add(node)
                return false
        }
        let buckets = match (indexed.get(signature.field)) {
            case Some(found) => found
            case None =>
                let created = HashMap<ValueKey, ArrayList<AlphaNode>>()
                indexed[signature.field] = created
                created
        }
        match (buckets.get(value)) {
            case Some(nodes) => nodes.add(node)
            case None =>
                let nodes = ArrayList<AlphaNode>()
                nodes.add(node)
                buckets[value] = nodes
        }
        true
    }

    /** 按值分发：命中桶的链头继续传播，再补跑未建索引的链头。 */
    func propagate(session: ReteSession, handle: FactHandle, fact: Fact): Unit {
        let hits = ArrayList<AlphaNode>()
        for ((field, buckets) in indexed) {
            let raw = match (fact.get(field)) {
                case Some(value) => value
                case None => continue
            }
            let key = match (RootDispatch.keyOf(raw)) {
                case Some(found) => found
                case None => continue
            }
            match (buckets.get(key)) {
                case Some(nodes) =>
                    for (node in nodes) {
                        hits.add(node)
                        node.propagate(session, handle, fact)
                    }
                case None => ()
            }
        }
        for (node in unindexed) {
            node.propagate(session, handle, fact)
        }
        if (indexed.size > 0) {
            // 记下等值命中的链头；撤销时只回收这些节点（未建索引的链头另行遍历）。
            session.recordAlphaHits(handle, hits.toArray())
        }
    }

    /** 撤销时补跑的链头（未建等值索引的那些）。 */
    func unindexedHeads(): ArrayList<AlphaNode> {
        unindexed
    }

    private static func keyOf(raw: Any): ?ValueKey {
        try {
            Some(ValueKey.of(raw))
        } catch (e: Exception) {
            None
        }
    }
}

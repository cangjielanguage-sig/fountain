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
import fountain::f_rule.fact.{Fact, FactHandle}

/**
 * 根节点：按 `typeTag` 路由到 alpha 链（`doc/04-rete-network.md` §3）。
 *
 * 一个类型可以有多个链头（不同首约束），因此这里保存列表而不是单指针。
 * 没有任何链头的类型直接忽略，不抛错（R-13/R-20）。
 *
 * 等值首约束的链头额外进入 [RootDispatch] 的按值索引：事实只计算一次字段值就能
 * 定位到命中的链头，不必对着同类型的上百个链头逐个跑测试闭包。
 */
public class RootNode <: ReteNode {
    private let id_: Int64
    private let heads_: HashMap<String, ArrayList<AlphaNode>>
    private let dispatches_: HashMap<String, RootDispatch>

    public init(id: Int64) {
        this.id_ = id
        this.heads_ = HashMap<String, ArrayList<AlphaNode>>()
        this.dispatches_ = HashMap<String, RootDispatch>()
    }

    public prop id: Int64 {
        get() {
            id_
        }
    }

    public func addHead(node: AlphaNode): Unit {
        let tag = node.signature.typeTag
        match (heads_.get(tag)) {
            case Some(nodes) =>
                for (existing in nodes) {
                    if (existing.signature == node.signature) {
                        return
                    }
                }
                nodes.add(node)
            case None =>
                let nodes = ArrayList<AlphaNode>()
                nodes.add(node)
                heads_[tag] = nodes
        }
        let _ = dispatchFor(tag).add(node)
    }

    /** 该类型没有链头时返回空数组。 */
    public func heads(typeTag: String): Array<AlphaNode> {
        match (heads_.get(typeTag)) {
            case Some(nodes) => nodes.toArray()
            case None => Array<AlphaNode>()
        }
    }

    public func typeTags(): Array<String> {
        let out = ArrayList<String>()
        for ((tag, _) in heads_) {
            out.add(tag)
        }
        out.toArray()
    }

    public func propagate(session: ReteSession, handle: FactHandle, fact: Fact): Unit {
        // 运行期只读：按值分发，未建索引的链头才逐条测试。
        match (dispatches_.get(fact.typeTag)) {
            case Some(dispatch) => dispatch.propagate(session, handle, fact)
            case None => ()
        }
    }

    public func retract(session: ReteSession, handle: FactHandle): Unit {
        let dispatch = match (dispatches_.get(handle.typeTag)) {
            case Some(found) => found
            case None => return
        }
        // 有插入时的命中记录：只回收命中的等值链头 + 未建索引的链头。
        match (session.alphaHits(handle)) {
            case Some(hits) =>
                for (node in hits) {
                    node.retract(session, handle)
                }
                for (node in dispatch.unindexedHeads()) {
                    node.retract(session, handle)
                }
                return
            case None => ()
        }
        // 没有记录（旧数据或非本会话插入）：退回逐链头回收，正确性优先。
        match (heads_.get(handle.typeTag)) {
            case Some(nodes) =>
                for (node in nodes) {
                    node.retract(session, handle)
                }
            case None => ()
        }
    }

    private func dispatchFor(typeTag: String): RootDispatch {
        match (dispatches_.get(typeTag)) {
            case Some(found) => found
            case None =>
                let created = RootDispatch()
                dispatches_[typeTag] = created
                created
        }
    }
}

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
 */
public class RootNode <: ReteNode {
    private let id_: Int64
    private let heads_: HashMap<String, ArrayList<AlphaNode>>

    public init(id: Int64) {
        this.id_ = id
        this.heads_ = HashMap<String, ArrayList<AlphaNode>>()
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
        for (node in heads(fact.typeTag)) {
            node.propagate(session, handle, fact)
        }
    }

    public func retract(session: ReteSession, handle: FactHandle): Unit {
        for (node in heads(handle.typeTag)) {
            node.retract(session, handle)
        }
    }
}

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

import std.collection.ArrayList
import fountain::f_rule.fact.{Fact, FactHandle}

/**
 * alpha 节点：单事实约束测试（`doc/04-rete-network.md` §3、§6.1）。
 *
 * 同一签名在**单个分片内**只建一个节点，多个模式共享。一个模式的多个约束
 * 通过 [children] 串成链；任一环节测试失败即短路。节点既可以是链头（由
 * `RootNode` 路由），也可以是别的节点的后继，从而形成共享 DAG。
 *
 * 每个节点都有自己的 memory（即使不作为模式结尾），这样撤销时可以判断
 * "该事实是否通过了本节点"，决定是否继续向下游传播。
 */
public class AlphaNode <: ReteNode {
    private let id_: Int64
    public let signature: AlphaSignature
    /** 本节点的测试；类型过滤节点恒为 true。 */
    public let test: (Fact) -> Bool
    private let children_: ArrayList<AlphaNode>
    private let rightSinks_: ArrayList<RightSink>
    private let leftSinks_: ArrayList<LeftConsumer>

    public init(id: Int64, signature: AlphaSignature, test: (Fact) -> Bool) {
        this.id_ = id
        this.signature = signature
        this.test = test
        this.children_ = ArrayList<AlphaNode>()
        this.rightSinks_ = ArrayList<RightSink>()
        this.leftSinks_ = ArrayList<LeftConsumer>()
    }

    public prop id: Int64 {
        get() {
            id_
        }
    }

    public func addChild(child: AlphaNode): Unit {
        // 同一条路径可能被多条规则复用，重复连接会让同一事实被传播两次。
        for (existing in children_) {
            if (existing.signature == child.signature) {
                return
            }
        }
        children_.add(child)
    }

    /** 本 memory 作为右侧输入时，下游 beta join 的登记。 */
    public func addRightConsumer(sink: RightSink): Unit {
        rightSinks_.add(sink)
    }

    /** 本 memory 作为左侧输入（首模式）时，用哑令牌驱动的下游登记。 */
    public func addLeftConsumer(sink: TokenSink, binding: String): Unit {
        leftSinks_.add(LeftConsumer(sink, binding))
    }

    public func children(): Array<AlphaNode> {
        children_.toArray()
    }

    public func leftConsumers(): Array<LeftConsumer> {
        leftSinks_.toArray()
    }

    public func rightConsumers(): Array<RightSink> {
        rightSinks_.toArray()
    }

    /** 沿链传播；测试失败立即短路，memory 幂等时不再重复通知下游。 */
    public func propagate(session: ReteSession, handle: FactHandle, fact: Fact): Unit {
        if (!test(fact)) {
            return
        }
        let memory = session.alphaMemory(id)
        if (!memory.add(handle, fact)) {
            return
        }
        for (sink in rightSinks_) {
            sink.rightActivate(session, handle, fact)
        }
        for (consumer in leftSinks_) {
            consumer.sink.leftActivate(session, Token.root(handle, consumer.binding, fact))
        }
        for (child in children_) {
            child.propagate(session, handle, fact)
        }
    }

    /** 撤销；事实没通过本节点时直接返回（R-12）。 */
    public func retract(session: ReteSession, handle: FactHandle): Unit {
        let memory = session.alphaMemory(id)
        let fact = match (memory.fact(handle)) {
            case Some(found) => found
            case None => return
        }
        if (!memory.remove(handle)) {
            return
        }
        for (sink in rightSinks_) {
            sink.rightRetract(session, handle)
        }
        for (consumer in leftSinks_) {
            consumer.sink.leftRetract(session, Token.root(handle, consumer.binding, fact))
        }
        for (child in children_) {
            child.retract(session, handle)
        }
    }

    public func toString(): String {
        "AlphaNode(${id}, ${signature})"
    }
}

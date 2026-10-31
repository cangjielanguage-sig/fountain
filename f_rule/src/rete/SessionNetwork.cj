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

import std.collection.HashMap
import fountain::f_rule.fact.{Fact, FactHandle}

/**
 * `(space, session)` 级网络运行态（`doc/04-rete-network.md` §1.1、D3）。
 *
 * 网络结构（节点、连接）由 `ReteNetwork` 持有并在进程内共享；本类只持有
 * 该会话的 alpha/beta memory 与激活汇，因此两个会话的事实与令牌互不可见。
 */
public class SessionNetwork <: ReteSession {
    private let network_: ReteNetwork
    public let session: String
    private let sink_: ActivationSink
    private let alphaMems_: HashMap<Int64, AlphaMemory>
    private let betaMems_: HashMap<Int64, BetaMemory>

    public init(network: ReteNetwork, session: String, sink: ActivationSink) {
        this.network_ = network
        this.session = session
        this.sink_ = sink
        this.alphaMems_ = HashMap<Int64, AlphaMemory>()
        this.betaMems_ = HashMap<Int64, BetaMemory>()
    }

    public prop sink: ActivationSink {
        get() {
            sink_
        }
    }

    public func network(): ReteNetwork {
        network_
    }

    public func alphaMemory(nodeId: Int64): AlphaMemory {
        match (alphaMems_.get(nodeId)) {
            case Some(found) => found
            case None =>
                let created = AlphaMemory(nodeId)
                alphaMems_[nodeId] = created
                created
        }
    }

    public func betaMemory(nodeId: Int64): BetaMemory {
        match (betaMems_.get(nodeId)) {
            case Some(found) => found
            case None =>
                let created = BetaMemory(nodeId)
                betaMems_[nodeId] = created
                created
        }
    }

    /** 插入事实：路由到本分片根节点。 */
    public func assert(handle: FactHandle, fact: Fact): Unit {
        network_.rootNode().propagate(this, handle, fact)
    }

    public func retract(handle: FactHandle): Unit {
        network_.rootNode().retract(this, handle)
    }

    /** 等价于 retract + assert，句柄 id 不变（§6.3）。 */
    public func update(handle: FactHandle, fact: Fact): Unit {
        retract(handle)
        assert(handle, fact)
    }

    /** 所有 alpha memory 的事实总数（分片隔离断言用）。 */
    public func alphaSize(): Int64 {
        var total: Int64 = 0
        for ((_, memory) in alphaMems_) {
            total += memory.size()
        }
        total
    }

    /** 所有 beta memory 的令牌总数。 */
    public func tokenCount(): Int64 {
        var total: Int64 = 0
        for ((_, memory) in betaMems_) {
            total += memory.size()
        }
        total
    }

    public func betaMemoryCount(): Int64 {
        betaMems_.size
    }

    public func clearMemories(): Unit {
        alphaMems_.clear()
        betaMems_.clear()
    }
}

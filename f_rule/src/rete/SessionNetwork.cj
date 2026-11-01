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

import fountain::f_rule.agenda.ActivationSink
import std.collection.HashMap
import fountain::f_rule.fact.{Fact, FactHandle}
import fountain::f_rule.rule.RuleFailureGuard

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
    private let productions_: HashMap<Int64, BetaProductions>
    /** 事实插入时命中的 alpha 链头；撤销时直接按记录回收，避免全链头扫描。 */
    private let alphaHits_: HashMap<FactHandle, Array<AlphaNode>>
    /** 规则集级求值失败状态；与终端节点共享同一实例。 */
    private let failureGuard_: RuleFailureGuard

    public init(network: ReteNetwork, session: String, sink: ActivationSink,
        failureGuard!: RuleFailureGuard = RuleFailureGuard("standalone")) {
        this.network_ = network
        this.session = session
        this.sink_ = sink
        this.failureGuard_ = failureGuard
        this.alphaMems_ = HashMap<Int64, AlphaMemory>()
        this.betaMems_ = HashMap<Int64, BetaMemory>()
        this.productions_ = HashMap<Int64, BetaProductions>()
        this.alphaHits_ = HashMap<FactHandle, Array<AlphaNode>>()
    }

    public prop sink: ActivationSink {
        get() {
            sink_
        }
    }

    /** 规则集级求值失败状态（alpha/beta 节点报告约束异常时使用）。 */
    public prop failureGuard: RuleFailureGuard {
        get() {
            failureGuard_
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

    public func betaProductions(nodeId: Int64): BetaProductions {
        match (productions_.get(nodeId)) {
            case Some(found) => found
            case None =>
                let created = BetaProductions()
                productions_[nodeId] = created
                created
        }
    }

    /** 插入事实：路由到本分片根节点。 */
    public func assert(handle: FactHandle, fact: Fact): Unit {
        network_.rootNode().propagate(this, handle, fact)
    }

    public func retract(handle: FactHandle): Unit {
        network_.rootNode().retract(this, handle)
        let _ = alphaHits_.remove(handle)
    }

    public func recordAlphaHits(handle: FactHandle, hits: Array<AlphaNode>): Unit {
        alphaHits_[handle] = hits
    }

    public func alphaHits(handle: FactHandle): ?Array<AlphaNode> {
        alphaHits_.get(handle)
    }

    public func forgetAlphaHits(handle: FactHandle): Unit {
        let _ = alphaHits_.remove(handle)
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
        productions_.clear()
        alphaHits_.clear()
    }
}

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
import fountain::f_rule.agenda.{Activation, ActivationSink}
import fountain::f_rule.exception.{RuleErrorCode, RuleException}
import fountain::f_rule.fact.{Fact, FactHandle}

/** 追踪激活汇：维护会话级激活集合，并转发给真正的下游（议程）。 */
class TrackingSink <: ActivationSink {
    private let delegate: ActivationSink
    private let items: ArrayList<Activation>

    TrackingSink(delegate: ActivationSink) {
        this.delegate = delegate
        this.items = ArrayList<Activation>()
    }

    public func add(activation: Activation): Unit {
        if (contains(activation)) {
            return
        }
        items.add(activation)
        delegate.add(activation)
    }

    public func remove(activation: Activation): Unit {
        var i = 0
        while (i < items.size) {
            if (items[i] == activation) {
                items.remove(at: i)
                delegate.remove(activation)
                return
            }
            i += 1
        }
    }

    public func activations(): Array<Activation> {
        items.toArray()
    }

    private func contains(activation: Activation): Bool {
        for (item in items) {
            if (item == activation) {
                return true
            }
        }
        false
    }
}

/**
 * 会话运行态：聚合该会话的多张空间分片（`doc/04-rete-network.md` §1.1、D3）。
 *
 * 每个分片一个 `SessionNetwork`，共享同一个激活汇；分片按 `generation` 判断是否
 * 被重建，重建后自动换用新的运行态而不影响其他分片（R-18）。
 *
 * `Naive` 模式只保留事实并按需调用注入的朴素匹配器，用于差分与调试；
 * 公开 API 不暴露该开关。
 */
/** Naive 模式保存的 `(句柄, 事实)` 对。 */
class NaiveEntry {
    let handle: FactHandle
    let fact: Fact

    NaiveEntry(handle: FactHandle, fact: Fact) {
        this.handle = handle
        this.fact = fact
    }
}

public class SessionRuntime {
    private let sharded_: ShardedNetwork
    public let session: String
    private let tracking_: TrackingSink
    private let shards_: HashMap<String, SessionNetwork>
    private let generations_: HashMap<String, Int64>
    private let naiveFacts_: HashMap<String, ArrayList<NaiveEntry>>

    public init(sharded: ShardedNetwork, session: String, sink: ActivationSink) {
        this.sharded_ = sharded
        this.session = session
        this.tracking_ = TrackingSink(sink)
        this.shards_ = HashMap<String, SessionNetwork>()
        this.generations_ = HashMap<String, Int64>()
        this.naiveFacts_ = HashMap<String, ArrayList<NaiveEntry>>()
    }

    public func assert(space: String, handle: FactHandle, fact: Fact): Unit {
        match (sharded_.mode) {
            case MatcherMode.Rete => shard(space).assert(handle, fact)
            case MatcherMode.Naive => factsOf(space).add(NaiveEntry(handle, fact))
        }
    }

    public func retract(space: String, handle: FactHandle): Unit {
        match (sharded_.mode) {
            case MatcherMode.Rete => shard(space).retract(handle)
            case MatcherMode.Naive =>
                let facts = factsOf(space)
                var i = 0
                while (i < facts.size) {
                    if (facts[i].handle == handle) {
                        facts.remove(at: i)
                        break
                    }
                    i += 1
                }
        }
    }

    public func update(space: String, handle: FactHandle, fact: Fact): Unit {
        match (sharded_.mode) {
            case MatcherMode.Rete => shard(space).update(handle, fact)
            case MatcherMode.Naive =>
                retract(space, handle)
                assert(space, handle, fact)
        }
    }

    /** 取 `(space, session)` 运行态；分片被重建后自动换新。 */
    public func shard(space: String): SessionNetwork {
        let network = match (sharded_.network(space)) {
            case Some(found) => found
            case None =>
                throw RuleException(
                    RuleErrorCode.UNKNOWN_FACT_SPACE,
                    "规则集未声明事实空间 ${space}"
                )
        }
        match (shards_.get(space)) {
            case Some(existing) =>
                match (generations_.get(space)) {
                    case Some(generation) =>
                        if (generation == network.generation) {
                            return existing
                        }
                    case None => ()
                }
            case None => ()
        }
        let created = network.open(session, tracking_)
        shards_[space] = created
        generations_[space] = network.generation
        created
    }

    /** 会话级激活视图（跨空间统一收集，R-19）。 */
    public func activations(): Array<Activation> {
        match (sharded_.mode) {
            case MatcherMode.Rete => tracking_.activations()
            case MatcherMode.Naive =>
                let evaluator = match (sharded_.naiveEvaluator()) {
                    case Some(found) => found
                    case None => throw RuleException(
                        RuleErrorCode.ILLEGAL_STATE,
                        "Naive 模式缺少朴素匹配后端"
                    )
                }
                evaluator(sharded_.ruleSet.rules, naiveFactMap())
        }
    }

    public func alphaSize(space: String): Int64 {
        shard(space).alphaSize()
    }

    public func tokenCount(space: String): Int64 {
        shard(space).tokenCount()
    }

    private func factsOf(space: String): ArrayList<NaiveEntry> {
        match (naiveFacts_.get(space)) {
            case Some(found) => found
            case None =>
                let created = ArrayList<NaiveEntry>()
                naiveFacts_[space] = created
                created
        }
    }

    private func naiveFactMap(): HashMap<String, Array<Fact>> {
        let out = HashMap<String, Array<Fact>>()
        for ((space, facts) in naiveFacts_) {
            let values = ArrayList<Fact>()
            for (entry in facts) {
                values.add(entry.fact)
            }
            out[space] = values.toArray()
        }
        out
    }
}

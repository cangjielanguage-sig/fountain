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
import std.sync.Mutex
import fountain::f_rule.agenda.{Activation, ActivationSink}
import fountain::f_rule.exception.{RuleErrorCode, RuleException}
import fountain::f_rule.fact.Fact
import fountain::f_rule.rule.{Rule, RuleSet}

/** 匹配后端：`Naive` 只用于测试与差分，公开 API 不暴露。 */
public enum MatcherMode <: ToString {
    | Rete
    | Naive

    public func toString(): String {
        match (this) {
            case Rete => "Rete"
            case Naive => "Naive"
        }
    }
}

/** 朴素匹配后端签名；由测试包注入，避免 `rete` 反向依赖 `test`。 */
public type NaiveActivationFn = (Array<Rule>, HashMap<String, Array<Fact>>) -> Array<Activation>

/**
 * 按 `FactSpace` 分片的网络集合（`doc/04-rete-network.md` §1.1、§9）。
 *
 * 每个空间一个 `ReteNetwork`，节点共享只在分片内发生。规则按 `rule.factSpace`
 * 分组后分别构建；`rebuild(space)` 只替换目标分片，其他分片的 structure 与
 * 运行态都不受影响（R-16~R-18）。
 */
public class ShardedNetwork {
    /** 结构缓存：只保留最近一个 `RuleSet` 的网络，避免缓存无限增长。 */
    private static let cacheMtx = Mutex()
    private static var cachedRuleSet: ?RuleSet = None
    private static var cachedNetwork: ?ShardedNetwork = None

    private let ruleSet_: RuleSet
    private let shards_: HashMap<String, ReteNetwork>
    private let spaces_: ArrayList<String>
    private var mode_: MatcherMode
    private let naive_: ?NaiveActivationFn

    public init(ruleSet: RuleSet, mode!: MatcherMode = MatcherMode.Rete,
        naive!: ?NaiveActivationFn = None) {
        this.ruleSet_ = ruleSet
        this.shards_ = HashMap<String, ReteNetwork>()
        this.spaces_ = ArrayList<String>()
        this.mode_ = mode
        this.naive_ = naive
        let registry = ruleSet.registry
        for (space in registry.ids()) {
            spaces_.add(space)
            shards_[space] = ShardedNetwork.buildShard(ruleSet, space)
        }
    }

    public prop ruleSet: RuleSet {
        get() {
            ruleSet_
        }
    }

    /**
     * 取规则集对应的网络结构；同一 `RuleSet` 实例重复调用命中缓存（B-06）。
     *
     * 结构构建完成后即冻结，只有 memory 随会话变化，因此多个引擎共享同一份结构是
     * 安全的。缓存只保留最近一次构建，`RuleSet` 变化后自然替换，不会无限增长。
     */
    public static func shared(ruleSet: RuleSet): ShardedNetwork {
        let cached = synchronized(cacheMtx) {
            var found: ?ShardedNetwork = None
            match (cachedRuleSet) {
                case Some(existing) =>
                    if (refEq(existing, ruleSet)) {
                        found = cachedNetwork
                    }
                case None => ()
            }
            found
        }
        match (cached) {
            case Some(found) => return found
            case None => ()
        }
        let built = ShardedNetwork(ruleSet)
        synchronized(cacheMtx) {
            cachedRuleSet = Some(ruleSet)
            cachedNetwork = Some(built)
        }
        built
    }

    public prop mode: MatcherMode {
        get() {
            mode_
        }
    }

    public func naiveEvaluator(): ?NaiveActivationFn {
        naive_
    }

    /** 声明顺序的空间列表。 */
    public func spaces(): Array<String> {
        spaces_.toArray()
    }

    public func network(space: String): ?ReteNetwork {
        shards_.get(space)
    }

    /** 只重建指定分片；其他分片对象保持原引用（R-18）。 */
    public func rebuild(space: String): Unit {
        if (!shards_.contains(space)) {
            throw RuleException(
                RuleErrorCode.UNKNOWN_FACT_SPACE,
                "规则集未声明事实空间 ${space}，无法重建分片"
            )
        }
        shards_[space] = ShardedNetwork.buildShard(ruleSet_, space)
    }

    /** 打开会话运行态；多个空间共享同一个激活汇（议程在会话级统一排序，R-19）。 */
    public func session(session: String, sink: ActivationSink): SessionRuntime {
        SessionRuntime(this, session, sink)
    }

    private static func buildShard(ruleSet: RuleSet, space: String): ReteNetwork {
        let network = ReteNetwork(space, expressionMode: ruleSet.expressionMode,
            failureGuard: ruleSet.failureGuard)
        network.build(ruleSet.rules, ruleSet.registry)
        network
    }
}

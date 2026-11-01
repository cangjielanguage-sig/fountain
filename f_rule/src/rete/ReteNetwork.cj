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
import std.collection.{ArrayList, HashMap}
import std.sync.Mutex
import fountain::f_rule.condition.{ExpressionMode, JitExpression, JoinConstraint}
import fountain::f_rule.exception.{RuleErrorCode, RuleException}
import fountain::f_rule.fact.{Fact, FactSpaceRegistry}
import fountain::f_rule.rule.{Rule, RuleFailureGuard}
import fountain::f_rule.runtime.RuleRuntime

/**
 * 单个 `FactSpace` 分片的 Rete 网络结构（`doc/04-rete-network.md` §2、§9）。
 *
 * 只保存节点与共享键：节点集合、连接关系在 `build` 完成后冻结，
 * 会话相关的 alpha/beta memory 由 `SessionNetwork` 持有（D3）。
 *
 * 节点计数不含根节点与终端：`nodeCount = alpha + beta`，对应文档 R-15 的
 * "节点数 = alpha 签名数 + join 数"。
 */
public class ReteNetwork {
    private static let genMtx = Mutex()
    private static var genCounter: Int64 = 0

    public let space: String
    /** 每次构建递增；会话据此判断分片是否被重建。 */
    public let generation: Int64
    private let root_: RootNode
    private let alphaNodes_: ArrayList<AlphaNode>
    private let alphaByKey_: HashMap<String, AlphaNode>
    private let betaNodes_: ArrayList<BetaNode>
    private let betaByKey_: HashMap<String, BetaNode>
    private let terminals_: ArrayList<TerminalNode>
    private var nextId_: Int64
    private var frozen_: Bool
    /** 脚本求值模式；`Interpreted` 时终端脚本走内置解释器。 */
    private let expressionMode_: ExpressionMode
    /** 构建脚本条件时解析绑定宿主类型；`build` 前为 `None`。 */
    private var registry_: ?FactSpaceRegistry
    /** 规则集级求值失败状态；终端节点共享同一实例。 */
    private let failureGuard_: RuleFailureGuard

    public init(space: String, expressionMode!: ExpressionMode = ExpressionMode.JitPreferred,
        failureGuard!: RuleFailureGuard = RuleFailureGuard("standalone")) {
        this.space = space
        this.expressionMode_ = expressionMode
        this.failureGuard_ = failureGuard
        this.registry_ = None
        this.generation = ReteNetwork.nextGeneration()
        this.root_ = RootNode(0)
        this.alphaNodes_ = ArrayList<AlphaNode>()
        this.alphaByKey_ = HashMap<String, AlphaNode>()
        this.betaNodes_ = ArrayList<BetaNode>()
        this.betaByKey_ = HashMap<String, BetaNode>()
        this.terminals_ = ArrayList<TerminalNode>()
        this.nextId_ = 1
        this.frozen_ = false
    }

    private static func nextGeneration(): Int64 {
        synchronized(genMtx) {
            genCounter += 1
            genCounter
        }
    }

    /**
     * 构建本分片的规则子集，完成后冻结。
     *
     * `rules` 中不属于本空间的规则被忽略；冻结后再次构建抛 `NETWORK_FROZEN`（R-11）。
     */
    public func build(rules: Array<Rule>, registry: FactSpaceRegistry): Unit {
        if (frozen_) {
            throw RuleException(
                RuleErrorCode.NETWORK_FROZEN,
                "Rete 网络（空间 ${space}）已冻结，不能再次构建"
            )
        }
        let _ = registry
        registry_ = Some(registry)
        NetworkBuilder.build(this, rules)
        frozen_ = true
    }

    /** 网络结构是否已冻结。 */
    public func frozen(): Bool {
        frozen_
    }

    /** 为指定会话打开运行态；同一网络可被多个会话复用（memory 隔离）。 */
    public func open(session: String, sink: ActivationSink): SessionNetwork {
        SessionNetwork(this, session, sink, failureGuard: failureGuard_)
    }

    public func rootNode(): RootNode {
        root_
    }

    public func alphaNodes(): Array<AlphaNode> {
        alphaNodes_.toArray()
    }

    public func betaNodes(): Array<BetaNode> {
        betaNodes_.toArray()
    }

    public func terminals(): Array<TerminalNode> {
        terminals_.toArray()
    }

    public func alphaNodeCount(): Int64 {
        alphaNodes_.size
    }

    public func betaNodeCount(): Int64 {
        betaNodes_.size
    }

    public func terminalCount(): Int64 {
        terminals_.size
    }

    /** 不含根与终端的节点数（R-15）。 */
    public func nodeCount(): Int64 {
        alphaNodes_.size + betaNodes_.size
    }

    /** 构建期分配节点 id；运行期不再调用。 */
    func nextNodeId(): Int64 {
        let id = nextId_
        nextId_ += 1
        id
    }

    /** 按签名共享 alpha 节点；路径相同才复用。 */
    func alphaNodeFor(signature: AlphaSignature, test: (Fact) -> Bool): AlphaNode {
        let key = signature.key()
        match (alphaByKey_.get(key)) {
            case Some(existing) => return existing
            case None => ()
        }
        let created = AlphaNode(nextNodeId(), signature, test)
        alphaByKey_[key] = created
        alphaNodes_.add(created)
        created
    }

    /** 按签名共享 beta 节点；探测计划在此一次性确定。 */
    func betaNodeFor(leftSource: BetaLeft, leftBinding: String, rightAlphaId: Int64,
        joins: Array<JoinConstraint>, rightBinding: String, ruleId: String): BetaNode {
        let signature = JoinSignature(leftSource, rightAlphaId, joins)
        let key = signature.key()
        match (betaByKey_.get(key)) {
            case Some(existing) =>
                existing.addRule(ruleId)
                return existing
            case None => ()
        }
        let plan = BetaNode.choosePlan(joins)
        let created = BetaNode(nextNodeId(), leftSource, leftBinding, rightAlphaId, joins,
            rightBinding, plan)
        created.addRule(ruleId)
        betaByKey_[key] = created
        betaNodes_.add(created)
        created
    }

    /** 每个规则一个终端，不参与共享。脚本在构建期编译，失败即抛 SCRIPT_COMPILE。 */
    func newTerminal(rule: Rule): TerminalNode {
        let scripts = ArrayList<JitExpression>()
        if (rule.scripts.size > 0) {
            let compiler = RuleRuntime.compiler()
            for (source in rule.scripts) {
                let expression = match (registry_) {
                    case Some(registry) =>
                        JitExpression.forRule(source, rule.patterns, registry, rule.factSpace,
                            compiler, expressionMode_, warn: false)
                    case None =>
                        if (expressionMode_ == ExpressionMode.Interpreted) {
                            JitExpression.interpretedOf(source)
                        } else {
                            JitExpression.of(source, compiler)
                        }
                }
                scripts.add(expression)
            }
        }
        let created = TerminalNode(nextNodeId(), rule, scripts: scripts.toArray(),
            failureGuard: failureGuard_)
        terminals_.add(created)
        created
    }

    public func toString(): String {
        "ReteNetwork(${space}, alpha=${alphaNodes_.size}, beta=${betaNodes_.size})"
    }
}

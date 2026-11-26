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
import fountain::f_rule.fact.{Fact, FactHandle}

/** 网络节点公共契约：构建期分配的唯一 id（共享键与传播顺序都依赖它）。 */
public interface ReteNode {
    prop id: Int64
}

/**
 * 左侧令牌消费方：beta 节点与终端节点。
 *
 * `session` 显式传入，使网络结构（节点、连接）能与会话运行态（memory）分离：
 * 同一张网络可以被多个会话复用，`(space, session)` 的令牌互不可见。
 */
public interface TokenSink {
    func leftActivate(session: ReteSession, token: Token): Unit
    func leftRetract(session: ReteSession, token: Token): Unit
}

/** 右侧事实消费方：beta 节点。 */
public interface RightSink {
    func rightActivate(session: ReteSession, handle: FactHandle, fact: Fact): Unit
    func rightRetract(session: ReteSession, handle: FactHandle): Unit
}

/**
 * 会话运行态视图。
 *
 * 网络结构只构建一次，alpha/beta memory 按 `(space, session)` 隔离；
 * 节点在传播时通过本接口取得当前会话的 memory 与激活汇。
 */
public interface ReteSession {
    prop sink: ActivationSink
    func alphaMemory(nodeId: Int64): AlphaMemory
    func betaMemory(nodeId: Int64): BetaMemory
    /** 该会话内某个 beta 节点的产出索引（会话运行态，不能放在共享节点上）。 */
    func betaProductions(nodeId: Int64): BetaProductions
    /** 记录某事实插入时命中的 alpha 链头，供撤销时按记录回收（不重算字段值）。 */
    func recordAlphaHits(handle: FactHandle, hits: Array<AlphaNode>): Unit
    /** 该事实的命中记录；没有记录时返回 `None`（撤销走逐链头回收）。 */
    func alphaHits(handle: FactHandle): ?Array<AlphaNode>
    /** 丢弃命中记录；撤销完成后调用。 */
    func forgetAlphaHits(handle: FactHandle): Unit
}

/** alpha memory 的左侧消费者：同一个共享 memory 可以被多个不同绑定名驱动。 */
public class LeftConsumer {
    public let sink: TokenSink
    public let binding: String

    public init(sink: TokenSink, binding: String) {
        this.sink = sink
        this.binding = binding
    }
}

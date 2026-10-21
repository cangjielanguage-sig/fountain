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
package fountain::fmq.cluster

import fountain::f_protocol.default.Message

/**
 * 节点间通信的最小抽象：元数据同步与备份只依赖这两个操作。
 *
 * 生产实现是 `NodeRegistry`（f_net 客户端 + 心跳）；单测用桩实现。
 */
protected interface MQNodeTransport {
    prop nodeCount: Int64

    prop selfIndex: Int64

    /** 向指定节点发一次请求；失败返回 `None`（不抛异常）。 */
    func send(index: Int64, message: Message): ?Message

    /**
     * 该节点是否「已知死亡」（最近一次调用失败）。
     *
     * 与 `isAlive` 不同：从未调用过的节点是「未知」，不算已知死亡。广播据此跳过
     * 已被判定不可达的节点，把补偿交给反熵同步（A40）。
     */
    func isKnownDead(index: Int64): Bool

    /**
     * 该节点最近一次交互确认存活。
     *
     * 与 `isKnownDead` 互补：两者都为假表示「未知」（从未成功调用过）。
     * 反熵据此分层选点：未知 → 存活 → 已知死亡（A40）。
     */
    func isAlive(index: Int64): Bool

    /** 环形后继节点（用于备份副本）。 */
    func successors(count: Int64): Array<Int64>
}

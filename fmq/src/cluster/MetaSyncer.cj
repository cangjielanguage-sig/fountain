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

import fountain::f_log.*
import fountain::f_mq.base.*
import fountain::f_mq.base.model.{MQSubscribeGroupMeta, MQTopicMeta}
import fountain::f_mq.base.payload.*
import fountain::f_mq.exception.MQServiceException
import fountain::f_protocol.default.Message
import fountain::fmq.meta.{MQAssignment, MetaApplyResult, MetaStore}

/**
 * 元数据复制：本地落盘 → 广播 → 回响应。
 *
 * 冲突按「先到者优先 + WARN」处理；广播失败只记 WARN，peer 恢复后由启动期全量同步补齐。
 */
protected class MetaSyncer {
    private static let log = LoggerFactory.getLogger("fountain::fmq.cluster.MetaSyncer")
    private static let SYNC_TIMEOUT_MULTIPLIER = 5

    private let store: MetaStore
    private let transport: MQNodeTransport

    protected init(store: MetaStore, transport: MQNodeTransport) {
        this.store = store
        this.transport = transport
    }

    /** 注册主题：分配 → 落盘（含轮转指针）→ 广播 → 返回分配。 */
    protected func registerTopic(meta: MQTopicMeta): MQTopicAssignment {
        if (!MQTopic.isValid(meta.topic)) {
            throw MQServiceException(MQErrorCode.INVALID_TOPIC, "invalid topic '${meta.topic}'")
        }
        if (meta.queueNum < 1) {
            throw MQServiceException(MQErrorCode.INVALID_TOPIC, "queueNum must be at least 1")
        }
        if (store.topicOf(meta.topic).isSome()) {
            throw MQServiceException(MQErrorCode.TOPIC_ALREADY_EXIST, "topic '${meta.topic}' already exists")
        }
        let nodeCount = transport.nodeCount
        if (nodeCount < 1) {
            throw MQServiceException(MQErrorCode.INTERNAL, "no node in cluster")
        }
        let start = store.nextStartNode % nodeCount
        let assignment = MQAssignment.allocate(meta.topic, meta.queueNum, nodeCount, start)
        let next = MQAssignment.nextStart(start, meta.queueNum, nodeCount)
        store.applyTopic(assignment, nextStart: next)
        broadcastTopic(assignment)
        assignment
    }

    protected func registerGroup(meta: MQSubscribeGroupMeta): MQResult {
        if (store.topicOf(meta.topic).isNone()) {
            throw MQServiceException(MQErrorCode.TOPIC_NOT_EXIST, "topic '${meta.topic}' does not exist")
        }
        if (store.groupExists(meta.topic, meta.subscribeGroup)) {
            throw MQServiceException(MQErrorCode.GROUP_ALREADY_EXIST,
                "subscribe group '${meta.subscribeGroup}' already exists on '${meta.topic}'")
        }
        store.applyGroup(meta)
        broadcastGroup(meta)
        MQResult(0, "ok")
    }

    protected func deregister(payload: MQDeregisterPayload): MQResult {
        if (payload.isTopic()) {
            if (!store.removeTopic(payload.topic)) {
                throw MQServiceException(MQErrorCode.TOPIC_NOT_EXIST, "topic '${payload.topic}' does not exist")
            }
        } else {
            if (!store.groupExists(payload.topic, payload.subscribeGroup)) {
                throw MQServiceException(MQErrorCode.GROUP_NOT_EXIST,
                    "subscribe group '${payload.subscribeGroup}' does not exist")
            }
            store.removeGroup(payload.topic, payload.subscribeGroup)
        }
        broadcastDelete(payload)
        MQResult(0, "ok")
    }

    /** 收到 peer 的 metaSync 请求 → 返回全量快照。 */
    protected func snapshotFor(requesterIndex: Int64): MQMetaSnapshot {
        store.snapshot()
    }

    /** 启动期：向第一个可达 peer 拉全量快照并合并。 */
    protected func syncFromPeers(): Unit {
        let nodeCount = transport.nodeCount
        if (nodeCount <= 1) {
            return
        }
        for (offset in 1..nodeCount) {
            let peer = (transport.selfIndex + offset) % nodeCount
            let response = transport.send(peer, MQProtocol.metaSync(MQMetaSyncRequest(transport.selfIndex)))
            if (let Some(message) <- response) {
                if (let Some(snapshot) <- MQProtocol.asPayload<MQMetaSnapshot>(message)) {
                    mergeSnapshot(snapshot)
                    return
                }
            }
        }
        log.warn("no peer reachable during startup sync, using local metadata")
    }

    protected func applyRemote(assignment: MQTopicAssignment): MetaApplyResult {
        store.applyTopic(assignment)
    }

    protected func applyRemoteGroup(meta: MQSubscribeGroupMeta): MetaApplyResult {
        store.applyGroup(meta)
    }

    protected func applyRemoteDelete(payload: MQDeregisterPayload): Bool {
        if (payload.isTopic()) {
            store.removeTopic(payload.topic)
        } else {
            store.removeGroup(payload.topic, payload.subscribeGroup)
        }
    }

    private func mergeSnapshot(snapshot: MQMetaSnapshot): Unit {
        for (assignment in snapshot.topics) {
            if (store.topicOf(assignment.topic).isNone()) {
                store.applyTopic(assignment)
            }
        }
        for (meta in snapshot.groups) {
            if (!store.groupExists(meta.topic, meta.subscribeGroup)) {
                store.applyGroup(meta)
            }
        }
        if (snapshot.nextStartNode > store.nextStartNode) {
            store.advanceNextStart(snapshot.nextStartNode)
        }
    }

    private func broadcastTopic(assignment: MQTopicAssignment): Unit {
        broadcast(MQProtocol.metaSync(assignment))
    }

    private func broadcastGroup(meta: MQSubscribeGroupMeta): Unit {
        broadcast(MQProtocol.metaSync(meta))
    }

    private func broadcastDelete(payload: MQDeregisterPayload): Unit {
        broadcast(MQProtocol.metaSync(payload))
    }

    private func broadcast(message: Message): Unit {
        let nodeCount = transport.nodeCount
        for (index in 0..nodeCount) {
            if (index == transport.selfIndex) {
                continue
            }
            if (transport.send(index, message).isNone()) {
                log.warn("metadata broadcast to node ${index} failed, peer will catch up on startup")
            }
        }
    }
}

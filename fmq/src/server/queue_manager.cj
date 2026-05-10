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
package fountain::fmq.server

import std.collection.HashMap
import fountain::f_util.crc64

/**
 * 队列管理器。
 * 管理主题到队列的创建、分布、生命周期。
 */
public class QueueManager {
    private let config: MqConfig
    private let log = LoggerFactory.getLogger('fountain::fmq.QueueManager')
    private let queues = HashMap<String, ArrayList<Queue>>()  // topic → [Queue]
    private var replicationManager: Option<ReplicationManager> = None
    private let nodeIndex: Int64

    public init(config: MqConfig, nodeIndex!: Int64 = 0) {
        this.config = config
        this.nodeIndex = nodeIndex
    }

    /**
     * 设置 ReplicationManager（用于 QueueWriter 同步）。
     */
    public func setReplicationManager(rm: ReplicationManager): Unit {
        this.replicationManager = rm
    }

    /**
     * 为主题创建队列。
     * 队列均匀分布在 mqHosts 节点上（CRC64 取模决定起始节点）。
     * 当前节点承担本节点所分配的队列。
     */
    public func createQueues(topic: String, queueCount: Int64): ArrayList<Queue> {
        let topicQueues = ArrayList<Queue>()
        for (i in 0..queueCount) {
            let ownerIndex = distribute(topic, i, config.mqHosts.size)
            if (ownerIndex == nodeIndex) {   // 本节点
                let q = Queue(topic, i, config.dataDir, config.segmentMaxSize)
                topicQueues.add(q)
            }
        }
        queues[topic] = topicQueues
        log.info{"created ${topicQueues.size} queues for topic ${topic} (node ${nodeIndex})"}
        topicQueues
    }

    /**
     * 销毁主题的所有队列。
     */
    public func destroyQueues(topic: String): Unit {
        if (let Some(topicQueues) <- queues.get(topic)) {
            for (q in topicQueues) {
                if (!q.isClosed()) { q.close() }
            }
            queues.remove(topic)
        }
    }

    /**
     * 获取指定主题的队列列表。
     */
    public func getQueues(topic: String): ?ArrayList<Queue> {
        queues.get(topic)
    }

    /**
     * 列出所有主题名。
     */
    public func listTopics(): ArrayList<String> {
        let result = ArrayList<String>()
        for ((topic, _) in queues) {
            result.add(topic)
        }
        result
    }

    /**
     * 获取指定 topic + index 的队列。
     */
    public func getQueue(topic: String, index: Int64): ?Queue {
        if (let Some(qs) <- queues.get(topic)) {
            for (q in qs) {
                if (q.index == index) {
                    return Some(q)
                }
            }
        }
        None
    }

    /**
     * 分布算法：CRC64 取模。
     * 计算 (topic:queueIndex) 的 CRC64，取模得到目标节点索引。
     */
    public func distribute(topic: String, queueIndex: Int64, nodeCount: Int64): Int64 {
        let key = "${topic}:${queueIndex}"
        let hash64 = crc64(key)
        Int64(hash64 % UInt64(nodeCount))
    }

    /**
     * 重新分配故障节点的队列到本节点。
     * 1. 遍历该主题的最大可能队列数
     * 2. 如果队列应属故障节点且尚未在本节点上创建，则在本地创建
     */
    public func reassign(failedNode: Int64): ArrayList<(String, Int64)> {
        let reassigned = ArrayList<(String, Int64)>()
        for ((topic, topicQueues) in queues) {
            let localIndices = ArrayList<Int64>()
            for (q in topicQueues) {
                localIndices.add(q.index)
            }
            let maxIndex = topicQueues.size + config.mqHosts.size
            for (i in 0..maxIndex) {
                let owner = distribute(topic, i, config.mqHosts.size)
                if (owner == failedNode && !localIndices.contains(i)) {
                    let q = Queue(topic, i, config.dataDir, config.segmentMaxSize)
                    topicQueues.add(q)
                    localIndices.add(i)
                    reassigned.add((topic, i))
                    log.warn{"reassign ${topic}[${i}] from node ${failedNode} to node ${nodeIndex}"}
                }
            }
        }
        if (reassigned.size == 0) {
            log.info{"reassign: no queues to reassign from node ${failedNode}"}
        }
        reassigned
    }

    /**
     * 恢复节点后的队列排空。
     * 将应属恢复节点的队列标记为 draining，仍留在 topicQueues 中继续分发
     * 剩余消息给消费者。当 log stream 读空后自动关闭并移除。
     */
    public func unreassign(restoredNode: Int64): ArrayList<(String, Int64)> {
        let returned = ArrayList<(String, Int64)>()
        for ((topic, topicQueues) in queues) {
            for (q in topicQueues) {
                let owner = distribute(topic, q.index, config.mqHosts.size)
                if (owner == restoredNode && !q.draining) {
                    q.draining = true
                    returned.add((topic, q.index))
                    log.info{"unreassign ${topic}[${q.index}]: drain mode"}
                }
            }
        }
        if (returned.size == 0) {
            log.info{"unreassign: no queues to return to node ${restoredNode}"}
        }
        returned
    }

    /**
     * 检查所有排空队列是否已完成，完成则移除。
     * 由外部定时器或 CONSUME 后调用。
     */
    public func drainCompleteCheck(): Unit {
        for ((topic, topicQueues) in queues) {
            var i: Int64 = 0
            while (i < topicQueues.size) {
                let q = topicQueues[i]
                if (q.draining && q.tryFinishDrain()) {
                    log.info{"drain complete: ${topic}[${q.index}], removed from node ${nodeIndex}"}
                    topicQueues.remove(at: i)
                } else {
                    i += 1
                }
            }
        }
    }

    /**
     * 标记为排空队列。
     */
    private static func markDraining(q: Queue): Unit { q.draining = true }

    /**
     * 为本节点的全部队列启动 writer/reader 线程。
     */
    public func startAll(): Unit {
        let rm = if (let Some(ref) <- replicationManager) { ref } else { return }
        for ((_, topicQueues) in queues) {
            for (q in topicQueues) {
                let writer = QueueWriter(q, replicationManager: rm, queueSize: 1024)
                let reader = QueueReader(q)
                spawn { writer.run() }
                spawn { reader.run() }
            }
        }
    }

    public func close(): Unit {
        for ((_, topicQueues) in queues) {
            for (q in topicQueues) {
                if (!q.isClosed()) { q.close() }
            }
        }
    }
}

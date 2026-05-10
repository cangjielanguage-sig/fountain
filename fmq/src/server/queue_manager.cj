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

import std.collection.concurrent.ConcurrentHashMap
import std.sync.Mutex
import fountain::f_util.crc64

/**
 * 队列管理器。
 * 管理主题到队列的创建、分布、生命周期。
 */
public class QueueManager {
    private let config: MqConfig
    private let log = LoggerFactory.getLogger('fountain::fmq.QueueManager')
    private let queues = ConcurrentHashMap<String, ArrayList<MqQueue>>()  // topic → [MqQueue]
    private var replicationManager: Option<ReplicationManager> = None
    private let nodeIndex: Int64
    private let lock = Mutex()
    private let writers = ArrayList<QueueWriter>()  // 跟踪 writer 线程
    private let readers = ArrayList<QueueReader>()  // 跟踪 reader 线程

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
    public func createQueues(topic: String, queueCount: Int64): ArrayList<MqQueue> {
        let topicQueues = ArrayList<MqQueue>()
        for (i in 0..queueCount) {
            let ownerIndex = distribute(topic, i, config.mqHosts.size)
            if (ownerIndex == nodeIndex) {   // 本节点
                let q = MqQueue(topic, i, config.dataDir, config.segmentMaxSize)
                topicQueues.add(q)
            }
        }
        synchronized(lock) {
            queues[topic] = topicQueues
        }
        log.info{"created ${topicQueues.size} queues for topic ${topic} (node ${nodeIndex})"}
        topicQueues
    }

    /**
     * 销毁主题的所有队列。
     */
    public func destroyQueues(topic: String): Unit {
        let topicQueues: ?ArrayList<MqQueue>
        synchronized(lock) {
            topicQueues = queues.get(topic)
            queues.remove(topic)
        }
        if (let Some(qs) <- topicQueues) {
            for (q in qs) {
                if (!q.isClosed()) { q.close() }
            }
        }
    }

    /**
     * 获取指定主题的队列列表（防御性拷贝，多线程安全）。
     */
    public func getQueues(topic: String): ?ArrayList<MqQueue> {
        synchronized(lock) {
            if (let Some(qs) <- queues.get(topic)) {
                let copy = ArrayList<MqQueue>()
                for (q in qs) { copy.add(q) }
                Some(copy)
            } else { None }
        }
    }

    /**
     * 列出所有主题名。
     */
    public func listTopics(): ArrayList<String> {
        let result = ArrayList<String>()
        synchronized(lock) {
            for ((topic, _) in queues) {
                result.add(topic)
            }
        }
        result
    }

    /**
     * 获取指定 topic + index 的队列。
     */
    public func getQueue(topic: String, index: Int64): ?MqQueue {
        synchronized(lock) {
            if (let Some(qs) <- queues.get(topic)) {
                for (q in qs) {
                    if (q.index == index) {
                        return Some(q)
                    }
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
        synchronized(lock) {
            for ((topic, topicQueues) in queues) {
                let localIndices = ArrayList<Int64>()
                for (q in topicQueues) {
                    localIndices.add(q.index)
                }
                let maxIndex = topicQueues.size + config.mqHosts.size
                for (i in 0..maxIndex) {
                    let owner = distribute(topic, i, config.mqHosts.size)
                    if (owner == failedNode && !localIndices.contains(i)) {
                        let q = MqQueue(topic, i, config.dataDir, config.segmentMaxSize)
                        topicQueues.add(q)
                        localIndices.add(i)
                        reassigned.add((topic, i))
                        log.warn{"reassign ${topic}[${i}] from node ${failedNode} to node ${nodeIndex}"}
                    }
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
        synchronized(lock) {
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
        synchronized(lock) {
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
    }

    /**
     * 标记为排空队列。
     */

    /**
     * 为本节点的全部队列启动 writer/reader 线程。
     */
    public func startAll(): Unit {
        let rm = if (let Some(ref) <- replicationManager) { ref } else { return }
        let snapshot: ArrayList<(String, ArrayList<MqQueue>)>
        synchronized(lock) {
            snapshot = ArrayList<(String, ArrayList<MqQueue>)>()
            for ((topic, topicQueues) in queues) {
                snapshot.add((topic, topicQueues))
            }
        }
        for ((_, topicQueues) in snapshot) {
            for (q in topicQueues) {
                let writer = QueueWriter(q, replicationManager: rm, queueSize: 1024)
                let reader = QueueReader(q)
                writers.add(writer)
                readers.add(reader)
                spawn { writer.run() }
                spawn { reader.run() }
            }
        }
        log.info{"startAll: ${writers.size} writers, ${readers.size} readers started"}
    }

    public func close(): Unit {
        // 先关闭 writer 和 reader 线程（让它们退出循环）
        for (w in writers) { w.close() }
        for (r in readers) { r.close() }
        // 再关闭队列（SegmentedLog）
        let allQueues: ArrayList<MqQueue>
        synchronized(lock) {
            allQueues = ArrayList<MqQueue>()
            for ((_, topicQueues) in queues) {
                for (q in topicQueues) { allQueues.add(q) }
            }
        }
        for (q in allQueues) {
            if (!q.isClosed()) { q.close() }
        }
        log.info{"closed: stopped ${writers.size} writers, ${readers.size} readers"}
    }
}

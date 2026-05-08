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

/**
 * 队列管理器。
 * 管理主题到队列的创建、分布、生命周期。
 */
public class QueueManager {
    private let config: MqConfig
    private let log = LoggerFactory.getLogger('fountain::fmq.QueueManager')
    private let queues = HashMap<String, ArrayList<Queue>>()  // topic → [Queue]

    public init(config: MqConfig) {
        this.config = config
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
            if (ownerIndex == 0) {   // 本节点（简化为第一个节点）
                let q = Queue(topic, i, config.dataDir, config.segmentMaxSize)
                topicQueues.add(q)
            }
        }
        queues[topic] = topicQueues
        log.info{"created ${topicQueues.size} queues for topic ${topic}"}
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
     * 分布算法：hashCode 取模。
     */
    public func distribute(topic: String, queueIndex: Int64, nodeCount: Int64): Int64 {
        let key = "${topic}:${queueIndex}"
        let absHash = abs(key.hashCode())
        absHash % nodeCount
    }

    private static func abs(x: Int64): Int64 {
        if (x < 0) { -x } else { x }
    }

    /**
     * 为本节点的全部队列启动 writer/reader 线程。
     */
    public func startAll(): Unit {
        for ((_, topicQueues) in queues) {
            for (q in topicQueues) {
                let writer = QueueWriter(q, queueSize: 1024)
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

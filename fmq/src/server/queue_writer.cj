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

import std.collection.concurrent.ConcurrentLinkedQueue
import std.sync.AtomicBool

/**
 * 队列写线程。
 * 从 inboundQueue 接收消息，写入 SegmentedLog，同步到从节点。
 */
public class QueueWriter {
    private let queue: MqQueue
    private let replicationManager: ReplicationManager
    private let log = LoggerFactory.getLogger('fountain::fmq.QueueWriter')
    private let closed = AtomicBool(false)
    private let inboundQueue: ConcurrentLinkedQueue<Array<Byte>>

    public init(queue: MqQueue, replicationManager!: ReplicationManager, queueSize!: Int64 = 1024) {
        this.queue = queue
        this.replicationManager = replicationManager
        this.inboundQueue = ConcurrentLinkedQueue<Array<Byte>>()
    }

    /**
     * 提交数据到写入队列。
     */
    public func submit(data: Array<Byte>): Unit {
        inboundQueue.add(data)
    }

    /**
     * 写线程主循环。
     */
    public func run(): Unit {
        while (!closed.load()) {
            try {
                if (let Some(data) <- inboundQueue.remove()) {
                    queue.append(data)
                    queue.sync()
                    syncToSlaves(data)
                } else {
                    sleep(Duration.millisecond * 10)
                }
            } catch (e: Exception) {
                log.error{"QueueWriter error: ${e.message}"}
            }
        }
    }

    /**
     * 关闭 Writer。设置 closed 标志让 run() 循环退出。
     * 注意：不排空 inboundQueue 中的待处理消息。关闭前需确认无新提交。
     */
    public func close(): Unit { closed.store(true) }

    /**
     * 同步 message 到所有已注册的从节点。
     */
    private func syncToSlaves(data: Array<Byte>): Unit {
        let slaves = replicationManager.getSlaves()
        if (slaves.size == 0) { return }

        // 并行同步到每个从节点
        let futures = ArrayList<Future<Bool>>()
        for (slave in slaves) {
            futures.add(spawn { syncToSlave(slave.nodeId, data) })
        }

        // 等待至少一个从节点确认
        var confirmed: Int64 = 0
        for (f in futures) {
            if (f.get()) {
                confirmed += 1
                if (confirmed >= 1) { break }
            }
        }
        if (confirmed == 0) {
            log.warn{"sync: no slave confirmed"}
        }
    }

    /**
     * 向单个从节点发送同步数据。
     * ⚠️ 已知限制：当前版本未实现真正的网络同步。
     * syncToSlave 仅记录日志并返回 true，主从数据复制待后续版本实现。
     * TODO(v2): 通过 f_net::Client 向 slave 发送 MqBody("sync", data) 并等待确认。
     */
    private func syncToSlave(nodeId: String, data: Array<Byte>): Bool {
        try {
            // TODO: 实现真实网络同步 — 从 mqHosts 查询对端地址建立连接
            log.debug{"sync to slave ${nodeId}: ${data.size} bytes (stub: network sync not implemented)"}
            true
        } catch (e: Exception) {
            log.warn{"sync to slave ${nodeId} unexpected error: ${e.message}"}
            false
        }
    }
}

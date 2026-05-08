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
 * Slave 同步进度。
 */
public class SlaveProgress {
    let nodeId: String
    var syncedSeq: Int64      // 已确认的 seq
    var lastHeartbeat: DateTime

    public init(nodeId: String, syncedSeq!: Int64 = 0) {
        this.nodeId = nodeId
        this.syncedSeq = syncedSeq
        this.lastHeartbeat = DateTime.now()
    }
}

/**
 * 主从复制管理器。
 * 管理 Master/Slave 角色、数据同步、故障切换。
 */
public class ReplicationManager {
    private let config: MqConfig
    private let log = LoggerFactory.getLogger('fountain::fmq.ReplicationManager')

    // 角色状态
    private var isMaster: Bool = false
    private var masterNodeId: String = ""
    private var isSyncing: Bool = false       // Slave 同步中
    private var lastMasterSeq: Int64 = 0      // Slave 侧最后一次同步的 seq

    // Master 侧管理的 Slave
    private let slaves = HashMap<String, SlaveProgress>()

    public init(config: MqConfig) {
        this.config = config
    }

    // ───── Master 侧 API ─────

    /**
     * 提升本节点为 Master。
     */
    public func promoteToMaster(): Unit {
        isMaster = true
        masterNodeId = ""
        log.info("promoted to master")
    }

    /**
     * 降级本节点为 Slave。
     */
    public func demoteToSlave(masterId: String): Unit {
        isMaster = false
        masterNodeId = masterId
        log.info("demoted to slave of ${masterId}")
    }

    /**
     * 接收 Slave 的 SLAVEOF 请求。
     */
    public func onSlaveOf(nodeId: String): Bool {
        if (!isMaster) {
            log.warn("reject SLAVEOF from ${nodeId}: not master")
            return false
        }
        if (!slaves.contains(nodeId)) {
            slaves[nodeId] = SlaveProgress(nodeId)
            log.info("slave ${nodeId} registered")
        }
        true
    }

    /**
     * 获取所有已注册的 Slave。
     */
    public func getSlaves(): ArrayList<SlaveProgress> {
        let result = ArrayList<SlaveProgress>()
        for ((_, slave) in slaves) {
            result.add(slave)
        }
        result
    }

    // ───── Slave 侧 API ─────

    /**
     * 作为 Slave：发起 SLAVEOF 请求（Phase 5 占位）。
     */
    public func connectToMaster(masterId: String): Bool {
        this.masterNodeId = masterId
        this.isSyncing = true
        log.info("connecting to master ${masterId} (placeholder)")
        true
    }

    /**
     * 接收增量同步数据（Phase 5 占位）。
     */
    public func onIncrementalSync(data: Array<Byte>, seq: Int64): Unit {
        if (!isSyncing) { return }
        lastMasterSeq = seq
        log.debug("incremental sync: seq=${seq}")
    }

    // ───── 故障切换 ─────

    /**
     * 检测 Master 是否存活（Phase 5 占位）。
     */
    public func isMasterAlive(): Bool {
        // Phase 5: 通过 PING 检测 Master 是否存活
        true
    }

    /**
     * 故障切换：将本节点提升为 Master（Phase 5 占位）。
     * 返回 true 表示切换成功。
     */
    public func failoverToMaster(): Bool {
        if (isMaster) { return true }
        log.warn("failover: promoting to master")
        // Phase 5: 获取多数派确认，更新 fsync
        promoteToMaster()
        true
    }

    /**
     * 切回：旧 Master 恢复后，从当前 Master 同步数据，然后切回。
     */
    public func switchbackToMaster(originalMasterId: String): Bool {
        if (!isMaster) { return false }
        log.info("switchback: preparing to return master to ${originalMasterId}")
        // Phase 5: 确认数据一致，通知原始 Master 接管
        isMaster = false
        masterNodeId = originalMasterId
        true
    }

    /**
     * 获取本节点角色描述。
     */
    public func role(): String {
        if (isMaster) { "master" } else { "slave(${masterNodeId})" }
    }
}

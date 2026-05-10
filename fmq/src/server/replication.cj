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
import std.io.{ByteBuffer, SeekPosition}
import std.sync.Mutex
import fountain::f_codec.default.DefaultCodec
import fountain::f_protocol.default.{Message as ProtocolMessage, EncodedMessage}

/**
 * Slave 同步进度。
 */
public class SlaveProgress {
    let nodeId: String
    var syncedSeq: Int64
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
 * Slave 通过 f_net::Client 向 Master 发送 SLAVEOF/PING。
 */
public class ReplicationManager {
    private let config: MqConfig
    private let log = LoggerFactory.getLogger('fountain::fmq.ReplicationManager')

    // 角色状态
    private var isMaster: Bool = false
    private var masterNodeId: String = ""
    private var isSyncing: Bool = false
    private var lastMasterSeq: Int64 = 0

    // Master 侧管理的 Slave
    private let slaves = HashMap<String, SlaveProgress>()
    private let slavesMutex = Mutex()

    // Slave 侧到 Master 的连接
    private var masterConn: ?Client<ProtocolMessage, EncodedMessage, ProtocolMessage, MqBody, MessageID> = None

    public init(config: MqConfig) {
        this.config = config
    }

    // ───── Master 侧 API ─────

    public func promoteToMaster(): Unit {
        isMaster = true
        masterNodeId = ""
        log.info{"promoted to master"}
    }

    public func demoteToSlave(masterId: String): Unit {
        isMaster = false
        masterNodeId = masterId
        log.info{"demoted to slave of ${masterId}"}
    }

    public func onSlaveOf(nodeId: String): Bool {
        if (!isMaster) {
            log.warn{"reject SLAVEOF from ${nodeId}: not master"}
            return false
        }
        synchronized(slavesMutex) {
            if (!slaves.contains(nodeId)) {
                slaves[nodeId] = SlaveProgress(nodeId)
                log.info{"slave ${nodeId} registered"}
            }
        }
        true
    }

    public func getSlaves(): ArrayList<SlaveProgress> {
        let result = ArrayList<SlaveProgress>()
        synchronized(slavesMutex) {
            for ((_, slave) in slaves) {
                result.add(slave)
            }
        }
        result
    }

    // ───── Slave 侧 API ─────

    /**
     * 作为 Slave：连接 Master 并发送 SLAVEOF 命令。
     * @param masterAddr "host:port"
     */
    public func connectToMaster(masterId: String, masterAddr!: String = ""): Bool {
        if (masterAddr.isEmpty()) {
            // 从 mqHosts 找第一个非本节点
            if (config.mqHosts.size == 0) {
                log.error{"connectToMaster: no mq_hosts configured"}
                return false
            }
            return connectByAddress(masterId, config.mqHosts[0])
        }
        connectByAddress(masterId, masterAddr)
    }

    /**
     * 接收增量同步数据。
     */
    public func onIncrementalSync(data: Array<Byte>, seq: Int64): Unit {
        if (!isSyncing) { return }
        lastMasterSeq = seq
        log.debug{"incremental sync: seq=${seq}, ${data.size} bytes"}
    }

    // ───── 故障切换 ─────

    /**
     * 检测 Master 是否存活。通过连接发送 PING 验证。
     */
    public func isMasterAlive(): Bool {
        if (let Some(conn) <- masterConn) {
            try {
                let req = ProtocolMessage(Command.PING(0), MessageID(),
                    MqBody("ping", []).toData())
                let resp = conn.transfer(req.id, req, Duration.second * 3)
                resp.isSome()
            } catch (_: Exception) {
                false
            }
        } else {
            // 无连接时尝试连接一次
            if (masterNodeId.isEmpty() || config.mqHosts.size == 0) {
                return true
            }
            tryConnect()
        }
    }

    /**
     * 故障切换：提升本节点为 Master。
     */
    public func failoverToMaster(): Bool {
        if (isMaster) { return true }
        log.warn{"failover: promoting to master"}
        promoteToMaster()
        closeMasterConn()
        true
    }

    /**
     * 切回：当前 Master 准备将角色交还原 Master。
     */
    public func switchbackToMaster(originalMasterId: String): Bool {
        if (!isMaster) { return false }
        log.info{"switchback: returning master to ${originalMasterId}"}
        // Phase 7 简化：直接降级，原 Master 需自己提升
        isMaster = false
        masterNodeId = originalMasterId
        true
    }

    public func role(): String {
        if (isMaster) { "master" } else { "slave(${masterNodeId})" }
    }

    // ───── 私有方法 ─────

    private func connectByAddress(masterId: String, addr: String): Bool {
        let parts = addr.split(':')
        if (parts.size != 2) {
            log.error{"invalid master address: ${addr}"}
            return false
        }
        var localConn: ?Client<ProtocolMessage, EncodedMessage, ProtocolMessage, MqBody, MessageID> = None
        try {
            let host = parts[0]
            let port = UInt16(Int64.parse(parts[1]))
            let conn = Client<ProtocolMessage, EncodedMessage, ProtocolMessage, MqBody, MessageID>.builder(
                queueSize: 16, socketCount: 1, host: host, port: port,
                idGetter: { msg => msg.id },
                checkDuration: Duration.second * 30,
                checker: { _ => true }
            ).noDelay(true).build()
            localConn = conn
            this.masterConn = conn
            this.masterNodeId = masterId
            this.isSyncing = true

            let req = ProtocolMessage(Command.SLAVEOF(1), MessageID(),
                MqBody("slaveof", encodeNodeId(masterId)).toData())
            let resp = conn.transfer(req.id, req, Duration.second * 10)
            if (resp.isSome()) {
                log.info{"connected to master ${masterId} at ${addr}"}
                true
            } else {
                log.warn{"master ${masterId} did not respond to SLAVEOF"}
                closeConn(conn)
                this.masterConn = None
                false
            }
        } catch (e: Exception) {
            log.error{"connect to master ${masterId} failed: ${e.message}"}
            if (let Some(c) <- localConn) {
                if (!c.isClosed()) { c.close() }
            }
            this.masterConn = None
            false
        }
    }

    private func tryConnect(): Bool {
        if (config.mqHosts.size == 0) { return false }
        connectByAddress(masterNodeId, config.mqHosts[0])
    }

    private func closeMasterConn(): Unit {
        if (let Some(conn) <- masterConn) {
            if (!conn.isClosed()) { conn.close() }
            masterConn = None
        }
    }

    private static func encodeNodeId(nodeId: String): Array<Byte> {
        let buf = ByteBuffer()
        DefaultCodec()
            .encode(nodeId)
            .finish().copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        let size = buf.seek(SeekPosition.End(0))
        buf.seek(SeekPosition.Begin(0))
        let raw = Array<Byte>(Int64(size), repeat: 0u8)
        buf.read(raw)
        raw
    }

    private static func closeConn(conn: Client<ProtocolMessage, EncodedMessage, ProtocolMessage, MqBody, MessageID>): Unit {
        if (!conn.isClosed()) { conn.close() }
    }
}

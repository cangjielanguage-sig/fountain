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
package fountain::f_mq.client

import std.sync.{Mutex, AtomicBool}
import std.time.DateTime
import fountain::f_data.DataAny
import fountain::f_log.*
import fountain::f_mq.base.MQHost
import fountain::f_mq.exception.MQConnectionException
import fountain::f_net.client.Client
import fountain::f_protocol.default.Message

/**
 * 到各节点的 `Client<DataAny>` 连接池。
 *
 * 每节点一个槽位、一把锁：一个节点建连慢不会拖住其它节点（A17）；
 * 命中已关闭连接时当场重建（A11）；建连失败按 `200ms * 2^(n-1)` 退避、上限 5s，
 * 退避窗口内立即失败，避免每次调用都去撞一个死节点。
 */
internal class MQNodePool {
    private static let log = LoggerFactory.getLogger("fountain::f_mq.client.MQNodePool")
    private static let MAX_BACKOFF_MS: Int64 = 5000
    private static let BASE_BACKOFF_MS: Int64 = 200

    private let hosts: Array<String>
    private var slots: Array<?Client<DataAny>>
    private let nodeLocks: Array<Mutex>
    private let retryAt: Array<Int64>
    private let failures: Array<Int64>
    private let closed = AtomicBool(false)
    /** 建连函数：生产用真实 `Client.builder`，用例注入替身以复现慢节点与失败（0.4 的约定）。 */
    private let build: (String) -> Client<DataAny>
    private let nowMs: () -> Int64
    /** 测试观测点：在入口 closed 检查之后、节点锁之前插入挂起点（并发关闭用例用）。 */
    private let beforeLock: ?() -> Unit

    init(hosts: Array<String>, build!: ?(String) -> Client<DataAny> = None,
        nowMs!: () -> Int64 = {=> DateTime.now().toUnixTimeStamp().toMilliseconds()},
        beforeLock!: ?() -> Unit = None) {
        if (hosts.size == 0) {
            throw MQConnectionException("node list is empty")
        }
        for (entry in hosts) {
            if (MQHost.parseHost(entry).isNone()) {
                throw MQConnectionException("invalid node '${entry}', expect host:port")
            }
        }
        this.hosts = hosts
        this.slots = Array<?Client<DataAny>>(hosts.size) {_ => None<Client<DataAny>>}
        this.nodeLocks = Array<Mutex>(hosts.size) {_ => Mutex()}
        this.retryAt = Array<Int64>(hosts.size, repeat: 0)
        this.failures = Array<Int64>(hosts.size, repeat: 0)
        this.build = match (build) {
            case Some(f) => f
            case None => {entry => buildClient(entry)}
        }
        this.nowMs = nowMs
        this.beforeLock = beforeLock
    }

    prop size: Int64 {
        get() {
            hosts.size
        }
    }

    func hostOf(nodeIndex: Int64): String {
        hosts[nodeIndex]
    }

    /** 取（必要时创建）指定节点的连接；节点不可用时抛 `MQConnectionException`。 */
    func clientOf(nodeIndex: Int64): Client<DataAny> {
        if (nodeIndex < 0 || nodeIndex >= hosts.size) {
            throw MQConnectionException("node index ${nodeIndex} out of range [0, ${hosts.size})")
        }
        if (closed.load()) {
            throw MQConnectionException("client pool is closed")
        }
        match (beforeLock) {
            case Some(hook) => hook()
            case None => ()
        }
        synchronized(nodeLocks[nodeIndex]) {
            // 入口检查与加锁之间可能被 close() 插入：锁内必须复核，否则 close 返回后仍会建出活连接（T7.1）
            if (closed.load()) {
                throw MQConnectionException("client pool is closed")
            }
            match (slots[nodeIndex]) {
                case Some(existing) =>
                    if (!existing.isClosed()) {
                        return existing
                    }
                    // 连接被对端/心跳关闭：关掉旧句柄后重建，而不是永久报错
                    try {
                        existing.close()
                    } catch (e: Exception) {
                        // 旧句柄关不掉不影响重建，留 DEBUG 便于排查句柄泄漏
                        log.debug("node ${nodeIndex} (${hosts[nodeIndex]}) old connection close failed: ${e.message}")
                    }
                    slots[nodeIndex] = None<Client<DataAny>>
                case None => ()
            }
            let now = nowMs()
            if (now < retryAt[nodeIndex]) {
                throw MQConnectionException("node ${nodeIndex} (${hosts[nodeIndex]}) is backing off for " +
                    "${retryAt[nodeIndex] - now}ms")
            }
            try {
                let client = build(hosts[nodeIndex])
                slots[nodeIndex] = Some(client)
                failures[nodeIndex] = 0
                retryAt[nodeIndex] = 0
                client
            } catch (e: Exception) {
                failures[nodeIndex] = failures[nodeIndex] + 1
                let backoff = backoffOf(failures[nodeIndex])
                retryAt[nodeIndex] = now + backoff
                throw MQConnectionException("cannot connect to node ${nodeIndex} (${hosts[nodeIndex]})", e)
            }
        }
    }

    private static func backoffOf(failures: Int64): Int64 {
        if (failures <= 0) {
            return 0
        }
        // 200ms * 2^(n-1)，指数在 5s 处封顶
        var delay = BASE_BACKOFF_MS
        var i = 1i64
        while (i < failures && delay < MAX_BACKOFF_MS) {
            delay = delay * 2
            i++
        }
        if (delay > MAX_BACKOFF_MS) {
            MAX_BACKOFF_MS
        } else {
            delay
        }
    }

    private static func buildClient(entry: String): Client<DataAny> {
        let (host, port) = MQHost.parseHost(entry).getOrThrow {
            MQConnectionException("invalid node '${entry}', expect host:port")
        }
        Client<DataAny>.builder(
            address: "${host}:${port}",
            checkDuration: Duration.second * 30,
            checker: {=> Message.ping()}
        ).pingTimeout(Duration.second).build()
    }

    /**
     * 当前可尝试的节点下标。
     *
     * 连接池不预判节点死活：已关闭的槽位会在下次调用时重建，因此只要池没关，
     * 全部下标都返回，让发布/消费在节点恢复后能再次尝试（A11）。
     */
    func aliveNodes(): Array<Int64> {
        if (closed.load()) {
            return Array<Int64>()
        }
        Array<Int64>(hosts.size) {i => i}
    }

    /** 幂等关闭；逐节点取锁，避免与建连竞态。 */
    func close(): Unit {
        if (!closed.compareAndSwap(false, true)) {
            return
        }
        for (i in 0..slots.size) {
            synchronized(nodeLocks[i]) {
                match (slots[i]) {
                    case Some(c) =>
                        try {
                            c.close()
                        } catch (e: Exception) {
                            log.debug("node ${i} (${hosts[i]}) connection close failed: ${e.message}")
                        }
                        slots[i] = None<Client<DataAny>>
                    case None => ()
                }
            }
        }
    }

    func isClosed(): Bool {
        closed.load()
    }
}

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
package fountain::f_dbd.driver

import fountain::f_data.DataAny
import fountain::f_data.ToData
import fountain::f_net.client.Client
import fountain::f_protocol.default.*
import fountain::f_dbd.common.DbdErrorCode
import fountain::f_dbd.common.{DbdErrorPayload, QueryResultClosePayload, decodeStrict}
import fountain::f_dbd.exception.DbdException

/** 心跳周期：f_net 的 `Client` 会按它拆链重建，取远大于单次测试耗时的值以免干扰断言。 */
private let CHECK_DURATION: Duration = Duration.second * 30
/**
 * "不限时"：`Client.transfer` 必须给一个 `Duration`，从来不给 Subject 无限等待的可能。
 * 取 6 小时（远超任何现实查询），既能传达"等到底"的语义，又不会溢出或绕回。
 */
let NO_TIMEOUT: Duration = Duration.hour * 6

/**
 * f_dbd ↔ fdbm 的报文通道（设计 §5.9，**包内可见**）。
 *
 * 一条 `Client<DataAny>`（= 一条 TCP 连接）承载一个连接上的全部请求：`CONSUME` 请求语句/列读、
 * `UNSUBSCRIBE` 关闭游标。失败路径统一抛 `DbdException`：
 *
 * - `transfer` 返回 `None` ⇒ 视为**可能已错位**（服务端也许已经推进了状态）：按 §7.4 **立即关闭传输**，
 *   由 `DbdConnection.state` 反映成 `Broken`，后续请求一律 `IO`（fail-fast，不留半死连接）；
 * - `ERROR` ⇒ 还原成 `DbdException` 抛出（idyllically with code），连接保持可用；
 * - 非预期命令 ⇒ `PROTOCOL`。
 */
class DbdTransport {
    private let client: Client<DataAny>
    private let address: String

    init(host: String, port: UInt16) {
        address = '${host}:${port}'
        client = Client<DataAny>.builder(queueSize: 1024, socketCount: 1, host: host, port: port,
            checkDuration: CHECK_DURATION, checker: {=> Message.ping()}).build()
    }

    /**
     * 发一条 `CONSUME(once: true, QoS.AtMostOnce)` 并等 `RESP`。
     *
     * @return 响应报文；其 `data` 由调用方按期望的载荷类型自行解码。
     */
    func request<T>(payload: T, timeout: Duration): Message where T <: ToData {
        ensureOpen()
        let sending = Message.consume(once: true, qos: QoS.AtMostOnce, data: payload)
        match (client.transfer(sending, timeout)) {
            case Some(resp) => checked(resp, 'CONSUME')
            case None => throw onNoResponse(timeout)
        }
    }

    /** 发一条带载荷的 `UNSUBSCRIBE` 并等 `ACK`（关闭游标，§7.3）。 */
    func unsubscribe(payload: QueryResultClosePayload, timeout: Duration): Unit {
        ensureOpen()
        let sending = Message.unsubscribe(data: payload)
        match (client.transfer(sending, timeout)) {
            case Some(resp) =>
                match (resp.command) {
                    case Command.ACK => ()
                    case Command.ERROR => throw errorOf(resp)
                    case other => throw DbdException(DbdErrorCode.PROTOCOL,
                        'unexpected command ${other} in response to UNSUBSCRIBE ${payload.qid}')
                }
            case None => throw onNoResponse(timeout)
        }
    }

    /** 建链自检用的一次 PING（`connection_timeout`）：成功即认为链路可用。 */
    func ping(timeout: Duration): Unit {
        ensureOpen()
        match (client.transfer(Message.ping(), timeout)) {
            case Some(resp) =>
                match (resp.command) {
                    case Command.ACK => ()
                    case other => throw DbdException(DbdErrorCode.PROTOCOL, 'unexpected command ${other} in response to PING')
                }
            case None => throw onNoResponse(timeout)
        }
    }

    func isClosed(): Bool {
        client.isClosed()
    }

    /** 幂等关闭：抽出传输后在上面再请求一律 `IO`（不再等待任何超时）。 */
    func close(): Unit {
        try {
            client.close()
        } catch (_: Exception) {
            ()
        }
    }

    private func ensureOpen(): Unit {
        if (client.isClosed()) {
            throw DbdException(DbdErrorCode.IO, 'the transport to fdbm at ${address} is closed')
        }
    }

    /** 响应必须是 `RESP`；`ERROR` 还原成 `DbdException`，其余一律 `PROTOCOL`。 */
    private func checked(resp: Message, request: String): Message {
        match (resp.command) {
            case Command.RESP(_) => resp
            case Command.ERROR => throw errorOf(resp)
            case other => throw DbdException(DbdErrorCode.PROTOCOL, 'unexpected command ${other} in response to ${request}')
        }
    }

    /** 服务端回的 `ERROR`：`DbdErrorPayload` → `DbdException`（解不出时按 `PROTOCOL`，绝不返回半截错误）。 */
    private static func errorOf(resp: Message): DbdException {
        match (decodeStrict<DbdErrorPayload>(resp.data)) {
            case Some(payload) => DbdException(payload)
            case None => DbdException(DbdErrorCode.PROTOCOL, 'error response carries no DbdErrorPayload: ${resp.data}')
        }
    }

    /**
     * `transfer` 超时 / 断链：**立即关闭传输**并抛 `TIMEOUT`（传输已关 ⇒ 对端已断 ⇒ `IO`）。
     * 不关闭会让后续请求在同一条错位连接上"成功读到下一条响应"，把错位掩盖成数据错误。
     */
    private func onNoResponse(timeout: Duration): DbdException {
        let alreadyClosed = client.isClosed()
        close()
        if (alreadyClosed) {
            DbdException(DbdErrorCode.IO, 'the connection to fdbm at ${address} was broken')
        } else {
            DbdException(DbdErrorCode.TIMEOUT, 'no response from fdbm at ${address} within ${timeout.toMilliseconds()}ms')
        }
    }
}

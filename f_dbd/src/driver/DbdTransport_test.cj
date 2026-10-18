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

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_dbd.common.DbdErrorCode
import fountain::f_dbd.common.{DbdErrorPayload, QueryResultClosePayload, SqlPayload, UpdateResultPayload, decodeStrict}
import fountain::f_protocol.default.{Command, Message}

/** Step 3.4 `DbdTransport`（设计 §5.9）：先把进程内的 `StubFdbm` 替身钉死，再逐成员测传输。 */
@Test
public class DbdTransportTest {

    /** 替身自检：能收到 `CONSUME(SqlPayload)`、按注入的 handler 回 `RESP`，且记录按到达顺序。 */
    @TestCase
    public func stubRecordsRequestsInOrder(): Unit {
        let stub = StubFdbm(handler: {msg => resp(msg.id, data: UpdateResultPayload(3, 7))})
        let transport = DbdTransport('127.0.0.1', stub.port)
        try {
            let answer = transport.request(SqlPayload('insert into t values (?)'), Duration.second * 5)
            let arrived = waitUntil({=> stub.receivedCount() == 1})
            @Assert(arrived, true)
            let received = stub.received(0)
            @Assert(received.id.toString(), answer.id.toString())
            @Assert(commandName(received.command), 'CONSUME')
            match (decodeStrict<SqlPayload>(received.data)) {
                case Some(sql) => @Assert(sql.sql, 'insert into t values (?)')
                case None => @Assert(decodeStrict<SqlPayload>(received.data).isNone(), false)
            }
        } finally {
            transport.close()
            stub.close()
        }
    }

    /** `request` 正常路径：命令是 `RESP`，载荷解得出 `UpdateResultPayload` 且字段保真。 */
    @TestCase
    public func requestReturnsResp(): Unit {
        let stub = StubFdbm(handler: {msg => resp(msg.id, data: UpdateResultPayload(3, 7))})
        let transport = DbdTransport('127.0.0.1', stub.port)
        try {
            let answer = transport.request(SqlPayload('update t set a = 1'), Duration.second * 5)
            @Assert(commandName(answer.command), 'RESP')
            match (decodeStrict<UpdateResultPayload>(answer.data)) {
                case Some(r) =>
                    @Assert(r.rowCount, 3)
                    @Assert(r.lastInsertId, 7)
                case None => @Assert(decodeStrict<UpdateResultPayload>(answer.data).isNone(), false)
            }
        } finally {
            transport.close()
            stub.close()
        }
    }

    /** `ERROR` 回包 → `DbdException`（code / message / sqlState 一致），且**连接保持可用**。 */
    @TestCase
    public func errorResponseBecomesDbdException(): Unit {
        let stub = StubFdbm(handler: {msg => Message.error(msg.id,
            data: DbdErrorPayload(DbdErrorCode.SQL_SYNTAX, 'syntax error', sqlState: '42000'))})
        let transport = DbdTransport('127.0.0.1', stub.port)
        try {
            @Assert(codeOf { transport.request(SqlPayload('select'), Duration.second * 5) },
                DbdErrorCode.SQL_SYNTAX)
            // 连接保持可用：再发一条仍然拿到同一个 ERROR（服务端错误不该把连接判死）
            @Assert(codeOf { transport.request(SqlPayload('select 1'), Duration.second * 5) },
                DbdErrorCode.SQL_SYNTAX)
            @Assert(transport.isClosed(), false)
        } finally {
            transport.close()
            stub.close()
        }
    }

    /** 非 `RESP` / 非 `ERROR` 的命令（这里是 `ACK`）→ `PROTOCOL`。 */
    @TestCase
    public func unexpectedCommandIsProtocolError(): Unit {
        let stub = StubFdbm(handler: {msg => ack(msg.id)})
        let transport = DbdTransport('127.0.0.1', stub.port)
        try {
            @Assert(codeOf { transport.request(SqlPayload('select 1'), Duration.second * 5) },
                DbdErrorCode.PROTOCOL)
        } finally {
            transport.close()
            stub.close()
        }
    }

    /** 不回包 + 短超时 → `TIMEOUT`，且**传输已被关闭**（§7.4：不能把错位连接留给后续请求）。 */
    @TestCase
    public func noResponseWithinTimeoutClosesTransport(): Unit {
        let stub = StubFdbm()
        let transport = DbdTransport('127.0.0.1', stub.port)
        try {
            @Assert(codeOf { transport.request(SqlPayload('select 1'), Duration.millisecond * 300) },
                DbdErrorCode.TIMEOUT)
            @Assert(transport.isClosed(), true)
            // 关闭后再请求：立刻 `IO`（不再等一次新的超时）
            @Assert(codeOf { transport.request(SqlPayload('select 1'), Duration.millisecond * 300) },
                DbdErrorCode.IO)
        } finally {
            transport.close()
            stub.close()
        }
    }

    /** `UNSUBSCRIBE(qid)` → `ACK`：命令是 UNSUBSCRIBE，载荷解得出同一个 `qid`。 */
    @TestCase
    public func unsubscribeWaitsForAck(): Unit {
        let stub = StubFdbm(handler: {msg => ack(msg.id)})
        let transport = DbdTransport('127.0.0.1', stub.port)
        try {
            transport.unsubscribe(QueryResultClosePayload('q-42'), Duration.second * 5)
            let arrived = waitUntil({=> stub.receivedCount() == 1})
            @Assert(arrived, true)
            let received = stub.received(0)
            @Assert(commandName(received.command), 'UNSUBSCRIBE')
            match (decodeStrict<QueryResultClosePayload>(received.data)) {
                case Some(p) => @Assert(p.qid, 'q-42')
                case None => @Assert(decodeStrict<QueryResultClosePayload>(received.data).isNone(), false)
            }
        } finally {
            transport.close()
            stub.close()
        }
    }

    /** `UNSUBSCRIBE` 收到 `ERROR` → 异常原样冒出去（是否吞掉由 `QueryResultImpl.close()` 决定）。 */
    @TestCase
    public func unsubscribeErrorIsPropagated(): Unit {
        let stub = StubFdbm(handler: {msg => error(msg.id, DbdErrorCode.CURSOR_STATE)})
        let transport = DbdTransport('127.0.0.1', stub.port)
        try {
            @Assert(codeOf { transport.unsubscribe(QueryResultClosePayload('q-1'), Duration.second * 5) },
                DbdErrorCode.CURSOR_STATE)
        } finally {
            transport.close()
            stub.close()
        }
    }

    /** `UNSUBSCRIBE` 超时 → `TIMEOUT` 且传输已关。 */
    @TestCase
    public func unsubscribeTimeoutClosesTransport(): Unit {
        let stub = StubFdbm()
        let transport = DbdTransport('127.0.0.1', stub.port)
        try {
            @Assert(codeOf { transport.unsubscribe(QueryResultClosePayload('q-1'), Duration.millisecond * 300) },
                DbdErrorCode.TIMEOUT)
            @Assert(transport.isClosed(), true)
        } finally {
            transport.close()
            stub.close()
        }
    }

    /**
     * `ping()` 走 `connection_timeout` 那条自检路径：链路可用时不抛异常。
     *
     * `PING` 由 `Server` 内置回 `ACK`（不进 executor），所以"桩静默"这条路跟不出 —— 桩在线时即便
     * handler 返回 `None` 也照样 ACK；ping 的超时分支与 `request` 同一实现，由上面的用例覆盖。
     */
    @TestCase
    public func pingSucceedsWhenThePeerIsAlive(): Unit {
        let stub = StubFdbm()
        let transport = DbdTransport('127.0.0.1', stub.port)
        try {
            @Assert(messageOf { transport.ping(Duration.second * 5) }, '')
            @Assert(transport.isClosed(), false)
        } finally {
            transport.close()
            stub.close()
        }
    }

    /** `close()` 幂等，关闭后 `isClosed()` 为真（`f_dbpool` 的 checker 靠它判活）。 */
    @TestCase
    public func closeIsIdempotent(): Unit {
        let stub = StubFdbm()
        let transport = DbdTransport('127.0.0.1', stub.port)
        try {
            transport.close()
            @Assert(transport.isClosed(), true)
            transport.close()
            @Assert(transport.isClosed(), true)
        } finally {
            stub.close()
        }
    }
}

/** 命令的可读名：构造器带 payload（`RESP(b)` / `CONSUME(b)`），统一按名字断言。 */
func commandName(command: Command): String {
    match (command) {
        case Command.RESP(_) => 'RESP'
        case Command.CONSUME(_) => 'CONSUME'
        case Command.UNSUBSCRIBE => 'UNSUBSCRIBE'
        case Command.ERROR => 'ERROR'
        case Command.ACK => 'ACK'
        case Command.PING(_) => 'PING'
        case other => other.toString()
    }
}

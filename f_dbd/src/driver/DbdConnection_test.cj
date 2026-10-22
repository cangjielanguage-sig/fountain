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

import std.database.sql.*
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.DataNone
import fountain::f_data.base.*
import fountain::f_dbd.common.{DbdErrorCode, NEXT_ROW, QueryResultClosePayload, QueryResultServerPayload,
    UpdateResultPayload, decodeStrict}
import fountain::f_dbd.exception.DbdException
import fountain::f_protocol.default.Message

/** Step 3.5 `DbdConnection`（设计 §5.4）：状态机、元信息、连接级结果集独占与关闭握手。 */
@Test
public class DbdConnectionTest {

    /** `Connected → Broken → Closed` 的状态机。 */
    @TestCase
    public func stateTransitions(): Unit {
        let online = StubFdbm()
        let healthy = connectTo(online)
        try {
            @Assert(healthy.state == ConnectionState.Connected, true)
            @Assert(healthy.isClosed(), false)
        } finally {
            healthy.close()
        }
        online.close()
        @Assert(healthy.state == ConnectionState.Closed, true)

        // 桩静默 → query 超时 → 传输 fail-fast → Broken
        let silent = StubFdbm()
        let broken = connectTo(silent, timeoutMs: '300')
        try {
            @Assert(codeOf { broken.prepareStatement('select 1').query() }, DbdErrorCode.TIMEOUT)
            @Assert(broken.state == ConnectionState.Broken, true)
            @Assert(broken.isClosed(), true)
        } finally {
            broken.close()
            silent.close()
        }
    }

    /** `prepareStatement` 每次返回新实例；空 SQL 直接 `PROTOCOL`（不发包）。 */
    @TestCase
    public func prepareStatementIsLocal(): Unit {
        let stub = StubFdbm()
        let connection = connectTo(stub)
        try {
            let a = connection.prepareStatement('select 1')
            let b = connection.prepareStatement('select 1')
            @Assert(a is DbdStatement && b is DbdStatement, true)
            // 各自独立：关掉一个不影响另一个（两次 prepare 不是同一实例）
            a.close()
            @Assert(a.isClosed(), true)
            @Assert(b.isClosed(), false)
            @Assert(codeOf { connection.prepareStatement('') }, DbdErrorCode.PROTOCOL)
            @Assert(stub.receivedCount(), 0)
        } finally {
            connection.close()
            stub.close()
        }
    }

    /** `createTransaction` 返回绑定本连接的事务，`begin` 真的发一条 SQL。 */
    @TestCase
    public func createTransactionBindsThisConnection(): Unit {
        let stub = StubFdbm(handler: {msg => resp(msg.id, data: UpdateResultPayload(0, 0))})
        let connection = connectTo(stub)
        try {
            let transaction = connection.createTransaction()
            @Assert(transaction is DbdTransaction, true)
            transaction.begin()
            let arrived = waitUntil({=> stub.receivedCount() == 1})
            @Assert(arrived, true)
            match (sqlOf(stub.received(0))) {
                case Some(sql) => @Assert(sql.sql, 'begin')
                case None => @Assert(false, true)
            }
        } finally {
            connection.close()
            stub.close()
        }
    }

    /** 元信息含 driver/version/url/user/database，**密码不出现在任何值里**。 */
    @TestCase
    public func metadataNeverLeaksPassword(): Unit {
        let stub = StubFdbm()
        let connection = connectTo(stub, password: 'p%40ss-secret')
        try {
            let meta = connection.getMetaData()
            @Assert(metaValue(meta, 'driver'), 'fdbm')
            @Assert(metaValue(meta, 'database'), 'db0')
            @Assert(metaValue(meta, 'user'), 'u')
            @Assert(metaValue(meta, 'url').contains('***'), true)
            for ((_, value) in meta) {
                @Assert(value.contains('p@ss-secret'), false)
                @Assert(value.contains('p%40ss-secret'), false)
            }
        } finally {
            connection.close()
            stub.close()
        }
    }

    /**
     * 连接级结果集独占（不变量 6）：
     * 结果集未关闭时同连接其他语句的执行一律 `CURSOR_STATE` 且**不发包**；
     * **已耗尽但未 `close()`** 同样被拒；`close()` 后恢复。
     */
    @TestCase
    public func openResultBlocksOtherStatements(): Unit {
        let script = ConnScript()
        let stub = StubFdbm(handler: {msg => script.handle(msg)})
        let connection = connectTo(stub)
        try {
            let querying = connection.prepareStatement('select id, name from t')
            let result = querying.query()
            @Assert(stub.receivedCount(), 1)
            @Assert(result.next(), true)
            @Assert(result.next(), false)
            let before = stub.receivedCount()

            let other = connection.prepareStatement('update t set a = 1')
            @Assert(codeOf { other.update() }, DbdErrorCode.CURSOR_STATE)
            @Assert(codeOf { other.query() }, DbdErrorCode.CURSOR_STATE)
            // 闸门在发包前：请求数一点没涨
            @Assert(stub.receivedCount(), before)

            // 关闭游标后恢复正常
            result.close()
            @Assert(stub.receivedCount(), before + 1) // 只有 UNSUBSCRIBE
            @Assert(other.update().rowCount, 3)
        } finally {
            connection.close()
            stub.close()
        }
    }

    /** `close()` 有未关闭游标时先 `UNSUBSCRIBE(qid)`，且幂等。 */
    @TestCase
    public func closeUnsubscribesOpenCursor(): Unit {
        let script = ConnScript()
        let stub = StubFdbm(handler: {msg => script.handle(msg)})
        let connection = connectTo(stub)
        try {
            let result = connection.prepareStatement('select id, name from t').query()
            @Assert(stub.receivedCount(), 1)
            let qid = stub.received(0).id.toString()
            connection.close()
            @Assert(connection.state == ConnectionState.Closed, true)
            @Assert(connection.isClosed(), true)

            let requests = stub.allReceived()
            @Assert(requests.size, 2)
            @Assert(commandName(requests[1].command), 'UNSUBSCRIBE')
            match (decodeStrict<QueryResultClosePayload>(requests[1].data)) {
                case Some(payload) => @Assert(payload.qid, qid)
                case None => @Assert(false, true)
            }
            // 幂等：第二次 close 不再发包
            connection.close()
            @Assert(stub.receivedCount(), 2)
        } finally {
            stub.close()
        }
    }
}

/**
 * 连接级用例的脚本：第一条 `SqlPayload` 当查询（回列信息），之后的 `SqlPayload` 当更新；
 * `NEXT_ROW` 按 `rows` 回 bool，列读回固定值，`UNSUBSCRIBE` 回 ACK。
 */
class ConnScript {
    var rows: Array<Bool> = [true, false]
    private var rowCursor: Int64 = 0
    private var sqlCount: Int64 = 0

    func handle(message: Message): ?Message {
        if (sqlOf(message).isSome()) {
            sqlCount += 1
            if (sqlCount == 1) {
                return resp(message.id, data: QueryResultServerPayload(twoColumnInfos()))
            }
            return resp(message.id, data: UpdateResultPayload(3, 0))
        }
        if (isClose(message)) {
            return ack(message.id)
        }
        match (columnOf(message)) {
            case Some(column) =>
                if (column.index == NEXT_ROW) {
                    let has = if (rowCursor < rows.size) { rows[rowCursor] } else { false }
                    rowCursor += 1
                    resp(message.id, data: has.toData())
                } else {
                    resp(message.id, data: DataNone.INSTANCE)
                }
            case None => ack(message.id)
        }
    }
}

/** 建一条到桩的连接（查询/更新默认 2s 超时，避免用例挂死）。 */
func connectTo(stub: StubFdbm, password!: String = 'p', timeoutMs!: String = '2000'): DbdConnection {
    let datasource = DbdDatasource(DbdUrl.parse(stub.url(password: password)))
    datasource.setOption(SqlOption.QueryTimeout, timeoutMs)
    datasource.setOption(SqlOption.UpdateTimeout, timeoutMs)
    let connection = datasource.connect()
    datasource.close()
    match (connection) {
        case c: DbdConnection => c
        case _ => throw DbdException(DbdErrorCode.CONFIG, 'the datasource did not return a DbdConnection')
    }
}

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
import std.io.{IOException, InputStream}
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.DataNone
import fountain::f_data.base.*
import fountain::f_dbd.common.{ColumnInfoImpl, DbdErrorCode, NEXT_ROW, QueryResultClosePayload,
    UpdateResultPayload, decodeStrict}
import fountain::f_protocol.default.Message

/** `read` 恒失败的流：`DbdStatement.encode` 必须把它包成 `CONVERSION`（D01）。 */
private class FailingStream <: InputStream {
    public func read(buffer: Array<Byte>): Int64 {
        throw IOException('boom')
    }
}

/** Step 3.6 `DbdStatement`（设计 §5.5）：参数、执行、deprecated 重载与选项覆盖。 */
@Test
public class DbdStatementTest {

    /** 参数按 0 起索引顺序发送；`setNull` 与空洞都编码成 `DataNone`。 */
    @TestCase
    public func parametersAreSentInOrder(): Unit {
        let stub = StubFdbm(handler: {msg => resp(msg.id, data: UpdateResultPayload(2, 9))})
        let connection = connectTo(stub)
        try {
            let statement = connection.prepareStatement('update t set a = ?, b = ?, c = ?')
            statement.set<String>(0, 'x')
            statement.setNull(2)
            let result = statement.update()
            @Assert(result.rowCount, 2)
            @Assert(result.lastInsertId, 9)

            let payload = sqlOf(stub.received(0)).getOrThrow()
            @Assert(payload.params.size, 3)
            @Assert(payload.params[0].data.toString(), 'x')
            @Assert(payload.params[1].data is DataNone, true) // 空洞
            @Assert(payload.params[2].data is DataNone, true) // setNull
        } finally {
            connection.close()
            stub.close()
        }
    }

    /** 同一 index 重复设值以最后一次为准。 */
    @TestCase
    public func lastSetWins(): Unit {
        let stub = StubFdbm(handler: {msg => resp(msg.id, data: UpdateResultPayload(0, 0))})
        let connection = connectTo(stub)
        try {
            let statement = connection.prepareStatement('update t set a = ?')
            statement.set<String>(0, 'first')
            statement.set<String>(0, 'second')
            statement.update()
            let payload = sqlOf(stub.received(0)).getOrThrow()
            @Assert(payload.params.size, 1)
            @Assert(payload.params[0].data.toString(), 'second')
        } finally {
            connection.close()
            stub.close()
        }
    }

    /** 负数 index → `CONVERSION`；不支持的类型 → `CONVERSION`（不把 `DataException` 漏出去）。 */
    @TestCase
    public func illegalParametersAreConversionErrors(): Unit {
        let stub = StubFdbm()
        let connection = connectTo(stub)
        try {
            let statement = connection.prepareStatement('update t set a = ?')
            @Assert(codeOf { statement.set<Int64>(-1, 1) }, DbdErrorCode.CONVERSION)
            @Assert(codeOf { statement.set<NotEncodable>(0, NotEncodable()) }, DbdErrorCode.CONVERSION)
            @Assert(codeOf { statement.set<InputStream>(0, FailingStream()) }, DbdErrorCode.CONVERSION)
            @Assert(stub.receivedCount(), 0)
        } finally {
            connection.close()
            stub.close()
        }
    }

    /** `query()` 返回带列信息的结果集；发送器已注入真实传输（首次 `next()` 就发包）。 */
    @TestCase
    public func queryReturnsResultWithColumns(): Unit {
        let script = QueryScript(twoColumnInfos(), [true, false])
        script.addCell(7.toData())
        let stub = StubFdbm(handler: {msg => script.handler(msg)})
        let connection = connectTo(stub)
        try {
            let result = connection.prepareStatement('select id, name from t').query()
            @Assert(result.columnInfos.size, 2)
            @Assert(result.columnInfos[0].name, 'id')
            @Assert(result.columnInfos[1].typeName, 'String')
            @Assert(result.next(), true)
            @Assert(result.get<Int64>(0), 7)
            result.close()
        } finally {
            connection.close()
            stub.close()
        }
    }

    /** 响应载荷类型不对 → `PROTOCOL`（判别线上形状，不做宽容降级）。 */
    @TestCase
    public func wrongResponsePayloadIsProtocolError(): Unit {
        let stub = StubFdbm(handler: {msg => resp(msg.id, data: UpdateResultPayload(1, 0))})
        let connection = connectTo(stub)
        try {
            @Assert(codeOf { connection.prepareStatement('select 1').query() }, DbdErrorCode.PROTOCOL)
        } finally {
            connection.close()
            stub.close()
        }
    }

    /** 服务端 `ERROR` 原样冒出，且连接仍可用（服务端错误不判死连接）。 */
    @TestCase
    public func updateErrorKeepsConnectionUsable(): Unit {
        let script = FailingUpdateScript()
        let stub = StubFdbm(handler: {msg => script.handle(msg)})
        let connection = connectTo(stub)
        try {
            @Assert(codeOf { connection.prepareStatement('update t set a = 1').update() },
                DbdErrorCode.SQL_SYNTAX)
            @Assert(connection.state == ConnectionState.Connected, true)
            @Assert(connection.prepareStatement('update t set a = 2').update().rowCount, 1)
        } finally {
            connection.close()
            stub.close()
        }
    }

    /** deprecated 重载等价于逐个 `set`，`SqlNullable*` 的 `None` → `DataNone`。 */
    @TestCase
    public func deprecatedParamsMatchSetCalls(): Unit {
        let stub = StubFdbm(handler: {msg => resp(msg.id, data: UpdateResultPayload(1, 0))})
        let connection = connectTo(stub)
        try {
            let statement = connection.prepareStatement('update t set a = ?, b = ?')
            statement.update([SqlBigInt(5), SqlNullableVarchar(None)])
            let payload = sqlOf(stub.received(0)).getOrThrow()
            @Assert(payload.params.size, 2)
            @Assert(payload.params[0].data.toString(), '5')
            @Assert(payload.params[1].data is DataNone, true)
        } finally {
            connection.close()
            stub.close()
        }
    }

    /** 语句级 `query_timeout` 覆盖连接级：桩静默时按它超时。 */
    @TestCase
    public func statementOptionOverridesConnection(): Unit {
        let stub = StubFdbm()
        let connection = connectTo(stub, timeoutMs: '5000')
        try {
            let statement = connection.prepareStatement('select 1')
            statement.setOption(SqlOption.QueryTimeout, '300')
            @Assert(codeOf { statement.query() }, DbdErrorCode.TIMEOUT)
        } finally {
            connection.close()
            stub.close()
        }
    }
}

/** Step 3.7 结果集接线：真实发送路径的请求序列（无 `CLOSE_CURSOR`）。 */
@Test
public class DbdResultWiringTest {

    /** `query → next → get → next(false) → close` 的报文序列与字段完全符合 §7.1。 */
    @TestCase
    public func requestSequenceMatchesProtocol(): Unit {
        let script = QueryScript(twoColumnInfos(), [true, false])
        script.addCell(42.toData())
        let stub = StubFdbm(handler: {msg => script.handler(msg)})
        let connection = connectTo(stub)
        try {
            let statement = connection.prepareStatement('select id, name from t')
            let result = statement.query()
            @Assert(result.next(), true)
            @Assert(result.get<Int64>(0), 42)
            @Assert(result.next(), false)
            result.close()

            let requests = stub.allReceived()
            @Assert(requests.size, 5)
            // 0: CONSUME(SqlPayload)
            @Assert(commandName(requests[0].command), 'CONSUME')
            match (sqlOf(requests[0])) {
                case Some(sql) => @Assert(sql.sql, 'select id, name from t')
                case None => @Assert(false, true)
            }
            // 1: CONSUME(CELL(NEXT_ROW))
            match (columnOf(requests[1])) {
                case Some(column) => @Assert(column.index, NEXT_ROW)
                case None => @Assert(false, true)
            }
            // 2: CONSUME(CELL(0, 0))
            match (columnOf(requests[2])) {
                case Some(column) =>
                    @Assert(column.index, 0)
                    @Assert(column.bufSize, 0)
                case None => @Assert(false, true)
            }
            // 3: 再推进一行
            match (columnOf(requests[3])) {
                case Some(column) => @Assert(column.index, NEXT_ROW)
                case None => @Assert(false, true)
            }
            // 4: UNSUBSCRIBE(qid) —— 关闭**不走列读通道**
            @Assert(commandName(requests[4].command), 'UNSUBSCRIBE')
            match (decodeStrict<QueryResultClosePayload>(requests[4].data)) {
                case Some(payload) => @Assert(payload.qid, requests[0].id.toString())
                case None => @Assert(false, true)
            }
        } finally {
            connection.close()
            stub.close()
        }
    }

    /** 未关闭结果集时发包被闸门拦住：断言桩的请求数不增长。 */
    @TestCase
    public func gateStopsPacketsBeforeSend(): Unit {
        let script = QueryScript(twoColumnInfos(), [true])
        let stub = StubFdbm(handler: {msg => script.handler(msg)})
        let connection = connectTo(stub)
        try {
            let result = connection.prepareStatement('select id, name from t').query()
            let before = stub.receivedCount()
            @Assert(codeOf { connection.prepareStatement('select 1').query() }, DbdErrorCode.CURSOR_STATE)
            @Assert(codeOf { connection.createTransaction().begin() }, DbdErrorCode.CURSOR_STATE)
            @Assert(stub.receivedCount(), before)
            result.close()
        } finally {
            connection.close()
            stub.close()
        }
    }
}

/** Step 3.8 流列端到端：分块读、`fetch_rows`、行切换失效。 */
@Test
public class DbdStreamTest {

    private func streamInfos(): Array<ColumnInfoImpl> {
        [
            ColumnInfoImpl('id', 'Int64', 20, 0, false, 21),
            ColumnInfoImpl('payload', 'InputStream', 0, 0, true, 0)
        ]
    }

    /** 3 块（2 字节 + 1 字节 + EOF）顺序读出；块请求带 `bufSize`。 */
    @TestCase
    public func readsBlocksInOrder(): Unit {
        let script = QueryScript(streamInfos(), [true, false])
        script.addBlock([1u8, 2u8])
        script.addBlock([3u8])
        script.addBlock([])
        let stub = StubFdbm(handler: {msg => script.handler(msg)})
        let connection = connectTo(stub)
        try {
            let statement = connection.prepareStatement('select id, payload from t')
            statement.setOption(SqlOption.FetchRows, '7')
            let result = statement.query()
            @Assert(result.next(), true)
            let before = stub.receivedCount()
            let stream = result.get<InputStream>(1)
            // `get<InputStream>` 只打开句柄，不发请求
            @Assert(stub.receivedCount(), before)

            let first = Array<Byte>(8, repeat: 0)
            @Assert(stream.read(first), 2)
            @Assert(first[0], 1u8)
            @Assert(first[1], 2u8)
            let second = Array<Byte>(8, repeat: 0)
            @Assert(stream.read(second), 1)
            @Assert(second[0], 3u8)
            let third = Array<Byte>(8, repeat: 0)
            @Assert(stream.read(third), 0) // EOF

            let requests = stub.allReceived()
            // Sql + NEXT_ROW + 3 次块请求
            @Assert(requests.size, 5)
            var i = 2
            while (i < 5) {
                match (columnOf(requests[i])) {
                    case Some(column) =>
                        @Assert(column.index, 1)
                        @Assert(column.bufSize, 7) // fetch_rows 生效
                    case None => @Assert(false, true)
                }
                i += 1
            }
            result.close()
        } finally {
            connection.close()
            stub.close()
        }
    }

    /** 行切换后旧流句柄失效（`CURSOR_STATE`），且不再发包。 */
    @TestCase
    public func advancingTheRowInvalidatesTheStream(): Unit {
        let script = QueryScript(streamInfos(), [true, true])
        script.addBlock([9u8])
        let stub = StubFdbm(handler: {msg => script.handler(msg)})
        let connection = connectTo(stub)
        try {
            let result = connection.prepareStatement('select id, payload from t').query()
            @Assert(result.next(), true)
            let stream = result.get<InputStream>(1)
            let buffer = Array<Byte>(8, repeat: 0)
            @Assert(stream.read(buffer), 1)
            @Assert(result.next(), true)
            let before = stub.receivedCount()
            @Assert(codeOf { stream.read(buffer) }, DbdErrorCode.CURSOR_STATE)
            @Assert(stub.receivedCount(), before)
            result.close()
        } finally {
            connection.close()
            stub.close()
        }
    }
}

/** 第一次更新回 `ERROR(SQL_SYNTAX)`，之后正常（验证服务端错误不判死连接）。 */
class FailingUpdateScript {
    private var calls: Int64 = 0

    func handle(message: Message): ?Message {
        calls += 1
        if (calls == 1) {
            error(message.id, DbdErrorCode.SQL_SYNTAX, message: 'bad sql')
        } else {
            resp(message.id, data: UpdateResultPayload(1, 0))
        }
    }
}

/** 不能被编码成参数的测试类型（没有 `ToData`）。 */
class NotEncodable {}

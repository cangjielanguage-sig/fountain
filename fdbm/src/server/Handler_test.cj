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
package fountain::fdbm.server

import std.collection.HashMap
import std.collection.concurrent.ConcurrentLinkedQueue
import std.net.{IPSocketAddress, TcpServerSocket}
import std.sync.AtomicInt64
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.{Data, DataAny, DataBool, DataString, ToData}
import fountain::f_dbd.common.*
import fountain::f_dbm.{IdGenerator, IdGeneratorException, PartitionAlgorithm}
import fountain::fdbm.exception.FdbmException
import fountain::f_log.LoggerFactory
import fountain::f_mockdb.*
import fountain::f_net.client.Client
import fountain::f_net.server.Server
import fountain::f_net.SocketBuffer
import fountain::f_protocol.default.*
import fountain::fdbm.config.{DatabaseNodeConfig, IdMakerConfig, LoadBalanceConfig, PoolConfig}
import fountain::fdbm.execute.{DbdSession, ExecutorDispatcher}
import fountain::fdbm.resources.DatabaseResources
import fountain::fdbm.route.{GlobalTableRouter, PartitionRouter, PartitionRule, StepPartition}

/**
 * 协议契约用例（开发计划阶段 8 Step 8.1）：真实回环 `Server<DataAny>` + `Client<DataAny>`，
 * 断言的是**线上报文**，不是内部调用。
 */
@Test
public class HandlerTest {
    private static let logger = LoggerFactory.getLogger('fountain::fdbm.server.HandlerTest')

    @TestCase
    public func queryHeaderThenRowsAndCells(): Unit {
        let harness = Harness(rows: [1, 2])
        let client = harness.client()
        try {
            let resp = client.transfer(consume(SqlPayload('select * from t where id = 1')),
                Duration.second * 5).getOrThrow()
            @Assert(matches(resp.command), true)
            let header = decodeStrict<QueryResultServerPayload>(resp.data).getOrThrow()
            @Assert(header.columnInfos.size, 1)
            @Assert(header.columnInfos[0].typeName, 'Int64')
            @Assert(next(client).data.toString(), 'true')
            @Assert(cell(client, 0).toString(), '1')
            @Assert(next(client).data.toString(), 'true')
            @Assert(cell(client, 0).toString(), '2')
            @Assert(next(client).data.toString(), 'false')
        } finally {
            client.close()
            harness.close()
        }
    }

    @TestCase
    public func emptyResultSetNeedsFirstNextRow(): Unit {
        let harness = Harness(rows: [])
        let client = harness.client()
        try {
            let resp = client.transfer(consume(SqlPayload('select * from t where id = 1')),
                Duration.second * 5).getOrThrow()
            @Assert(decodeStrict<QueryResultServerPayload>(resp.data).getOrThrow().columnInfos.size, 1)
            @Assert(next(client).data.toString(), 'false')
        } finally {
            client.close()
            harness.close()
        }
    }

    @TestCase
    public func cursorOperationsWithoutCursorAreCursorState(): Unit {
        let harness = Harness(rows: [1])
        let client = harness.client()
        try {
            @Assert(codeOf(client.transfer(consume(QueryResultColumnPayload.nextRow()),
                Duration.second * 5).getOrThrow()), DbdErrorCode.CURSOR_STATE)
            @Assert(codeOf(client.transfer(consume(QueryResultColumnPayload.cell(0)),
                Duration.second * 5).getOrThrow()), DbdErrorCode.CURSOR_STATE)
        } finally {
            client.close()
            harness.close()
        }
    }

    @TestCase
    public func unsubscribeClosesCursorAndIsIdempotent(): Unit {
        let harness = Harness(rows: [1])
        let client = harness.client()
        try {
            let query = client.transfer(consume(SqlPayload('select * from t where id = 1')),
                Duration.second * 5).getOrThrow()
            let qid = query.id.toString()
            @Assert(isAck(close(client, qid)), true)
            @Assert(isAck(close(client, qid)), true)
        } finally {
            client.close()
            harness.close()
        }
    }

    @TestCase
    public func closeAfterUnsubscribeRejectsCursorReads(): Unit {
        let harness = Harness(rows: [1])
        let client = harness.client()
        try {
            let query = client.transfer(consume(SqlPayload('select * from t where id = 1')),
                Duration.second * 5).getOrThrow()
            close(client, query.id.toString())
            @Assert(codeOf(client.transfer(consume(QueryResultColumnPayload.nextRow()),
                Duration.second * 5).getOrThrow()), DbdErrorCode.CURSOR_STATE)
            @Assert(codeOf(client.transfer(consume(QueryResultColumnPayload.cell(0)),
                Duration.second * 5).getOrThrow()), DbdErrorCode.CURSOR_STATE)
            // 重复关闭仍回 ACK
            @Assert(isAck(close(client, query.id.toString())), true)
        } finally {
            client.close()
            harness.close()
        }
    }

    @TestCase
    public func unsubscribeWithWrongQidKeepsCurrentCursor(): Unit {
        let harness = Harness(rows: [1])
        let client = harness.client()
        try {
            client.transfer(consume(SqlPayload('select * from t where id = 1')),
                Duration.second * 5).getOrThrow()
            @Assert(isAck(close(client, 'not-the-qid')), true)
            @Assert(next(client).data.toString(), 'true')
            @Assert(cell(client, 0).toString(), '1')
        } finally {
            client.close()
            harness.close()
        }
    }

    @TestCase
    public func unsupportedCommandAndPayloadAreProtocolErrors(): Unit {
        let harness = Harness(rows: [1])
        let client = harness.client()
        try {
            let ack = Message.ack(Message.consume(once: true, qos: QoS.AtMostOnce,
                data: SqlPayload('select 1')).id)
            @Assert(codeOf(client.transfer(ack, Duration.second * 5).getOrThrow()), DbdErrorCode.PROTOCOL)
            let mismatch = Message.consume(once: true, qos: QoS.AtMostOnce, data: DataString('nope'))
            @Assert(codeOf(client.transfer(mismatch, Duration.second * 5).getOrThrow()),
                DbdErrorCode.PROTOCOL)
        } finally {
            client.close()
            harness.close()
        }
    }

    @TestCase
    public func updateReturnsUpdateResult(): Unit {
        let harness = Harness(rows: [1], rowCount: 3)
        let client = harness.client()
        try {
            let resp = client.transfer(consume(SqlPayload('update t set name = 1 where id = 5')),
                Duration.second * 5).getOrThrow()
            @Assert(decodeStrict<UpdateResultPayload>(resp.data).getOrThrow().rowCount, 3)
        } finally {
            client.close()
            harness.close()
        }
    }

    /** 分组 INSERT 失败走真实 handler 回包；单连接池必须归还后才能继续查询。 */
    @TestCase
    public func insertGroupFailurePreservesSqlStateAndReturnsConnection(): Unit {
        let harness = Harness(rows: [1], maxSize: 1)
        let statements = ConcurrentLinkedQueue<String>()
        MOCKDB.execution = {sql, _ =>
            statements.add(sql)
            if (sql.startsWith('insert')) {
                throw SqlException('duplicate key', '23505', 0)
            }
            if (sql.startsWith('select')) {
                MOCKDB.addQueryResultColumnInfo(name: 'id', nullable: false, typeName: 'Int64')
                MOCKDB.addQueryResultRow([1])
            } else {
                MOCKDB.rowCount = 0
            }
        }
        let client = harness.client()
        try {
            let error = client.transfer(consume(SqlPayload("insert into t (id, name) values (1, 'duplicate')")),
                Duration.second * 5).getOrThrow()
            @Assert(codeOf(error), DbdErrorCode.DB_ERROR)
            let payload = decodeStrict<DbdErrorPayload>(error.data).getOrThrow()
            @Assert(payload.sqlState, '23505')
            @Assert(payload.message.contains('committed: []'), true)
            let failed = statements.toArray()
            @Assert(failed.size, 3)
            @Assert(failed[0], 'begin')
            @Assert(failed[1].startsWith('insert'), true)
            @Assert(failed[2], 'rollback')
            let response = client.transfer(consume(SqlPayload('select * from t where id = 1')),
                Duration.second * 5).getOrThrow()
            @Assert(matches(response.command), true)
            @Assert(next(client).data.toString(), 'true')
            @Assert(cell(client, 0).toString(), '1')
            @Assert(isAck(close(client, response.id.toString())), true)
        } finally {
            client.close()
            harness.close()
        }
    }

    @TestCase
    public func errorMappingPreservesOuterClassificationAndNestedSqlState(): Unit {
        let sql = SqlException('duplicate key', '23505', 0)
        let nested = FdbmException(DbdErrorCode.DB_ERROR, 'group failure',
            Exception('adapter context', FdbmException(DbdErrorCode.DB_ERROR, 'driver context', sql)))
        let group = databaseErrorPayload(nested)
        @Assert(group.errorCode(), DbdErrorCode.DB_ERROR)
        @Assert(group.message, 'group failure')
        @Assert(group.sqlState, '23505')
        let sequence = databaseErrorPayload(FdbmException(DbdErrorCode.ID_GENERATOR, 'sequence failed', nested))
        @Assert(sequence.errorCode(), DbdErrorCode.ID_GENERATOR)
        @Assert(sequence.message, 'sequence failed')
        @Assert(sequence.sqlState, '23505')
        let direct = databaseErrorPayload(sql)
        @Assert(direct.errorCode(), DbdErrorCode.DB_ERROR)
        @Assert(direct.sqlState, '23505')
        let internalPayload = databaseErrorPayload(Exception('outer context', sql))
        @Assert(internalPayload.errorCode(), DbdErrorCode.INTERNAL)
        @Assert(internalPayload.message, 'outer context')
        @Assert(internalPayload.sqlState, '23505')
        @Assert(databaseErrorPayload(IdGeneratorException('unsupported id')).sqlState, '')
        @Assert(databaseErrorPayload(FdbmException(DbdErrorCode.DB_ERROR, '23505 in text only')).sqlState, '')
    }

    @TestCase
    public func routingFailureIsMappedToError(): Unit {
        let harness = Harness(rows: [1])
        let client = harness.client()
        try {
            @Assert(codeOf(client.transfer(consume(SqlPayload('update t set name = 1')),
                Duration.second * 5).getOrThrow()), DbdErrorCode.ROUTE_FAILED)
            // 连接保持可用
            let resp = client.transfer(consume(SqlPayload('select * from t where id = 1')),
                Duration.second * 5).getOrThrow()
            @Assert(matches(resp.command), true)
        } finally {
            client.close()
            harness.close()
        }
    }

    @TestCase
    public func newStatementClosesPreviousCursor(): Unit {
        let harness = Harness(rows: [1])
        let client = harness.client()
        try {
            client.transfer(consume(SqlPayload('select * from t where id = 1')),
                Duration.second * 5).getOrThrow()
            let second = client.transfer(consume(SqlPayload('select * from t where id = 1')),
                Duration.second * 5).getOrThrow()
            @Assert(matches(second.command), true)
            @Assert(next(client).data.toString(), 'true')
        } finally {
            client.close()
            harness.close()
        }
    }

    @TestCase
    public func twoConnectionsHaveIndependentSessions(): Unit {
        let harness = Harness(rows: [1])
        let first = harness.client()
        let second = harness.client()
        try {
            first.transfer(consume(SqlPayload('select * from t where id = 1')),
                Duration.second * 5).getOrThrow()
            @Assert(codeOf(second.transfer(consume(QueryResultColumnPayload.nextRow()),
                Duration.second * 5).getOrThrow()), DbdErrorCode.CURSOR_STATE)
        } finally {
            first.close()
            second.close()
            harness.close()
        }
    }

    // ==================== 工具 ====================

    private func consume<T>(data: T): Message where T <: ToData {
        Message.consume(once: true, qos: QoS.AtMostOnce, data: data)
    }

    private func next(client: Client<DataAny>): Message {
        client.transfer(consume(QueryResultColumnPayload.nextRow()), Duration.second * 5).getOrThrow()
    }

    private func cell(client: Client<DataAny>, index: Int64): Data {
        client.transfer(consume(QueryResultColumnPayload.cell(index)),
            Duration.second * 5).getOrThrow().data
    }

    private func close(client: Client<DataAny>, qid: String): Message {
        let message = Message.unsubscribe(data: QueryResultClosePayload(qid))
        client.transfer(message, Duration.second * 5).getOrThrow()
    }

    private func matches(command: Command): Bool {
        match (command) {
            case Command.RESP(_) => true
            case _ => false
        }
    }

    private func isAck(message: Message): Bool {
        match (message.command) {
            case Command.ACK => true
            case _ => false
        }
    }

    private func codeOf(resp: Message): DbdErrorCode {
        match (resp.command) {
            case Command.ERROR =>
                match (decodeStrict<DbdErrorPayload>(resp.data)) {
                    case Some(payload) => payload.errorCode()
                    case None => DbdErrorCode.INTERNAL
                }
            case _ => DbdErrorCode.INTERNAL
        }
    }
}

/** 进程内服务端：真实回环连接 + mockdb 物理资源。 */
class Harness {
    let server: Server<DataAny>
    let context: ServerContext
    let resources: DatabaseResources
    let sessions: SessionRegistry
    let port: UInt16
    let buffers = ConcurrentLinkedQueue<SocketBuffer>()

    init(rows!: Array<Int64>, rowCount!: Int64 = 1, maxSize!: Int64 = 4, sweep!: Duration = Duration.second * 30) {
        MOCKDB.clear()
        MOCKDB.execution = {sql, _ =>
            if (sql.startsWith('select')) {
                MOCKDB.addQueryResultColumnInfo(name: 'id', nullable: false, typeName: 'Int64')
                for (row in rows) {
                    MOCKDB.addQueryResultRow([row])
                }
            } else {
                MOCKDB.rowCount = rowCount
            }
        }
        let nodes = [DatabaseNodeConfig('name0', '127.0.0.1', 3306u16, 'mockdb',
            ['db0', 'db1'], '', '')]
        let pool = PoolConfig(initSize: 0, minSize: 0, maxSize: maxSize, checkOnBorrowing: false,
            checkOnReturning: false, connectTimeout: Duration.second, maxWaiting: Duration.second)
        this.resources = DatabaseResources(nodes, pool, LoadBalanceConfig())
        let rules = [PartitionRule('db0', 't', 'id', StepPartition(['db0', 'db1'], 1000))]
        let globals = GlobalTableRouter([])
        let router = PartitionRouter(rules, None, HashMap<String, PartitionAlgorithm>(),
            knownDatabases: ['db0', 'db1'], globalTables: globals)
        let dispatcher = ExecutorDispatcher(router, globals, this.resources,
            IdMakerConfig('uuid', arg: Some('4')), 'db0', HashMap<String, IdGenerator>(), None)
        this.sessions = SessionRegistry(sweep, 'db0')
        this.context = ServerContext(this.sessions, dispatcher, CustomExtensions(),
            LoggerFactory.getLogger('fountain::fdbm.server.Harness'))
        this.port = uniquePort()
        this.server = Server<DataAny>(bindAt: port, checkDuration: Duration.second * 30,
            checker: {=> Message.ping()})
        let started = this.server
        let ctx = this.context
        spawn {
            try {
                started.start {buffer, message =>
                    buffers.add(buffer)
                    Some(FdbmHandler.handle(ctx, buffer, message))
                }
            } catch (_: Exception) {
                ()
            }
        }
    }

    /** 最近一次请求对应的服务端连接（会话键）。 */
    func lastBuffer(): SocketBuffer {
        buffers.toArray()[buffers.toArray().size - 1]
    }

    func client(): Client<DataAny> {
        waitForPort(port)
        Client<DataAny>.builder(queueSize: 1024, socketCount: 1, host: '127.0.0.1', port: port,
            checkDuration: Duration.second * 30, checker: {=> Message.ping()}).build()
    }

    func close(): Unit {
        try {
            server.close()
        } catch (_: Exception) {
            ()
        }
        sessions.closeAll()
        resources.close()
    }
}

private let PORT_COUNTER = AtomicInt64(0)

/** 进程内唯一的测试端口：计数器错开，避免并行用例的 `freePort` 撞车。 */
func uniquePort(): UInt16 {
    while (true) {
        let offset = PORT_COUNTER.fetchAdd(1)
        let port = UInt16(42000 + (offset % 2000))
        let probe = TcpServerSocket(bindAt: port)
        try {
            probe.bind()
            probe.close()
            return port
        } catch (_: Exception) {
            try {
                probe.close()
            } catch (_: Exception) {
                ()
            }
        }
    }
    0
}

/** 等监听就绪（最多 5s）：`start()` 在后台线程里绑定端口。 */
func waitForPort(port: UInt16): Bool {
    var attempts = 0
    while (attempts < 250) {
        try {
            let client = Client<DataAny>.builder(queueSize: 8, socketCount: 1, host: '127.0.0.1',
                port: port, checkDuration: Duration.second * 30,
                checker: {=> Message.ping()}).build()
            try {
                if (client.transfer(Message.ping(), Duration.millisecond * 200).isSome()) {
                    return true
                }
            } finally {
                client.close()
            }
        } catch (_: Exception) {
            ()
        }
        sleep(Duration.millisecond * 20)
        attempts += 1
    }
    false
}

func freePort(): UInt16 {
    let probe = TcpServerSocket(bindAt: 0)
    probe.bind()
    var port: UInt16 = 0
    match (probe.localAddress) {
        case addr: IPSocketAddress => port = addr.port
        case _ => port = 0
    }
    probe.close()
    port
}

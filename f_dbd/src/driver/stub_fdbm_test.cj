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

import std.collection.ArrayList
import std.collection.concurrent.ConcurrentLinkedQueue
import std.net.{IPSocketAddress, TcpServerSocket}
import fountain::f_data.{Data, DataAny, DataNone, ToData}
import fountain::f_data.base.*
import fountain::f_net.server.Server
import fountain::f_protocol.default.*
import fountain::f_dbd.common.DbdErrorCode
import fountain::f_dbd.common.DbdErrorPayload
import fountain::f_dbd.common.{ColumnInfoImpl, NEXT_ROW, QueryResultClosePayload, QueryResultColumnPayload,
    QueryResultServerPayload, SqlPayload, decodeStrict}

/**
 * 进程内的 **fdbm 桩**（开发计划「阶段 3 测试替身」）。
 *
 * 一个真实的 `Server<DataAny>`（回环 + 随机空闲端口），把收到的每条报文**按序**记录在队列里，
 * 并按用例注入的 `handler` 应答 —— `PING` 由 `Server` 自己回 `ACK`，不需要 handler 处理。
 *
 * 用例据此断言"客户端到底发了什么"（请求序列、载荷字段），而不是只断言"最后得到了什么"。
 */
class StubFdbm {
    private let server: Server<DataAny>
    private let records: ConcurrentLinkedQueue<Message> = ConcurrentLinkedQueue<Message>()
    let port: UInt16

    /** @param handler 按收到的请求给出应答；返回 `None` 表示"不回包"（模拟超时/丢包）。 */
    init(handler!: (Message) -> ?Message = {_ => None<Message>}) {
        port = freePort()
        server = Server<DataAny>(bindAt: port, checkDuration: Duration.second * 30, checker: {=> Message.ping()})
        spawn {
            try {
                server.start {_, request =>
                    records.add(request)
                    handler(request)
                }
            } catch (_: Exception) {
                // close() 会把阻塞在 accept() 上的循环带出来，属正常收尾
            }
        }
    }

    /** 该桩正在监听的端口对应的连接串。 */
    func url(database!: String = 'db0', user!: String = 'u', password!: String = 'p'): String {
        'fdbm://${user}:${password}@127.0.0.1:${port}/${database}'
    }

    /** 已收到的请求数（用于在断言"没发包"时先等一小会儿）。 */
    func receivedCount(): Int64 {
        records.toArray().size
    }

    /** 按到达顺序取第 `index` 条请求。 */
    func received(index: Int64): Message {
        records.toArray()[index]
    }

    /** 已收到的全部请求（按到达顺序）。 */
    func allReceived(): Array<Message> {
        records.toArray()
    }

    /** 收到的请求里，命令为 `CONSUME` 的那些（Node站位用得到）。 */
    func consumes(): Array<Message> {
        let out = ArrayList<Message>()
        for (m in allReceived()) {
            if (let Command.CONSUME(_) <- m.command) {
                out.add(m)
            }
        }
        out.toArray()
    }

    /** 清空记录（同一条连接上的多阶段用例可以分段断言）。 */
    func clear(): Unit {
        while (let Some(_) <- records.remove()) {
        }
    }

    func close(): Unit {
        server.close()
    }
}

/** 探测一个空闲端口：把 socket bind 到 0 端口看内核给了什么，再关掉给 `Server` 用。 */
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

/** 构造 RESP（与线上 fdbm 一致：`qos: AtMostOnce, ack: false`）。 */
func resp<T>(id: MessageID, data!: T): Message where T <: ToData {
    Message.resp(id, qos: QoS.AtMostOnce, ack: false, data: data)
}

/** 构造 ERROR（线上 fdbm 的所有失败路径都回它，绝不静默不回包）。 */
func error(id: MessageID, code: DbdErrorCode, message!: String = 'stub failure'): Message {
    Message.error(id, data: DbdErrorPayload(code, message))
}

/** 构造 ACK。 */
func ack(id: MessageID): Message {
    Message.ack(id)
}

/** 把请求载荷解成 `SqlPayload`（不是该类型 → `None`）。 */
func sqlOf(message: Message): ?SqlPayload {
    decodeStrict<SqlPayload>(message.data)
}

/** 把请求载荷解成 `QueryResultColumnPayload`（不是该类型 → `None`）。 */
func columnOf(message: Message): ?QueryResultColumnPayload {
    decodeStrict<QueryResultColumnPayload>(message.data)
}

/** 载荷是否为 `UNSUBSCRIBE` 的 `QueryResultClosePayload`。 */
func isClose(message: Message): Bool {
    match (decodeStrict<QueryResultClosePayload>(message.data)) {
        case Some(_) => true
        case None => false
    }
}

/**
 * 查询脚本：`CONSUME(SqlPayload)` → 查询首包（只含列信息）；`CONSUME(CELL(NEXT_ROW))` →
 * 按 `rows` 顺序回 `Bool`；`CONSUME(CELL(index))` → 按 `cells` 顺序回数据（默认 NULL）；
 * `UNSUBSCRIBE` → `ACK`。
 *
 * `ScriptedFdbm` 把它接到 `StubFdbm.handler` 上，用例只需准备脚本并断言 `StubFdbm` 的记录。
 */
class QueryScript {
    var infos: Array<ColumnInfoImpl> = []
    var rows: Array<Bool> = []
    let cells = ArrayList<Data>()
    private var rowCursor: Int64 = 0
    private var cellCursor: Int64 = 0

    init(infos: Array<ColumnInfoImpl>, rows: Array<Bool>) {
        this.infos = infos
        this.rows = rows
    }

    /** 排一个列读应答（按请求顺序消费）。 */
    func addCell(data: Data): QueryScript {
        cells.add(data)
        this
    }

    /** 排一个字节块应答（流列）；空数组表示 EOF。 */
    func addBlock(bytes: Array<Byte>): QueryScript {
        cells.add(bytes.toData())
        this
    }

    func handler(message: Message): ?Message {
        if (decodeStrict<SqlPayload>(message.data).isSome()) {
            return resp(message.id, data: QueryResultServerPayload(infos))
        }
        match (decodeStrict<QueryResultColumnPayload>(message.data)) {
            case Some(column) =>
                if (column.index == NEXT_ROW) {
                    let has = if (rowCursor < rows.size) { rows[rowCursor] } else { false }
                    rowCursor += 1
                    resp(message.id, data: has.toData())
                } else {
                    let cell = if (cellCursor < cells.size) { cells[cellCursor] } else { DataNone.INSTANCE }
                    cellCursor += 1
                    resp(message.id, data: cell)
                }
            case None => ack(message.id)
        }
    }
}

/** 两列（`Int64` / `String`）的最小列信息，供查询用例复用。 */
func twoColumnInfos(): Array<ColumnInfoImpl> {
    [
        ColumnInfoImpl('id', 'Int64', 20, 0, false, 21),
        ColumnInfoImpl('name', 'String', 64, 0, true, 64)
    ]
}

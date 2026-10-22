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
package fountain::f_dbd.common

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.ArrayList
import std.database.sql.*
import std.io.InputStream
import std.time.DateTime
import fountain::f_data.*
import fountain::f_data.base.*

/**
 * Step 1.9 `QueryResultImpl` 与 Step 1.10 `DbdInputStream`（设计 §3.10 / §3.11）。
 *
 * 全部用**桩发送器 + 桩 closer**，不起网络：状态机、无预读、无缓存、流列与关闭握手都能本地断言。
 */
@Test
public class QueryResultImplTest {

    /** 构造期**不发任何请求**，且首包只有列信息（没有 `hasData` 之类的行状态）。 */
    @TestCase
    public func constructionSendsNothing(): Unit {
        let stub = StubSender()
        let r = result(stub, ['Int64', 'String'])
        @Assert(stub.requests.size, 0)
        @Assert(r.columnInfos.size, 2)
        @Assert(r.columnInfos[0].name, 'c0')
        @Assert(r.columnInfos[0].typeName, 'Int64')
        @Assert(r.columnInfos[1].typeName, 'String')
        @Assert(r.isClosed(), false)
    }

    /** `columnInfos` 是 `Array<ColumnInfo>`（泛型不变，只能逐项转换），字段逐项保真。 */
    @TestCase
    public func columnInfosAreConvertedItemByItem(): Unit {
        let infos: Array<ColumnInfo> = result(StubSender(), ['Int64']).columnInfos
        @Assert(infos.size, 1)
        @Assert(infos[0].nullable, false)
        @Assert(infos[0].displaySize, 21)
    }

    /** 无预读：**首次 `next()` 就发 `NEXT_ROW`**；三行脚本 → true/true/false，桩计数 3。 */
    @TestCase
    public func firstNextSendsRequest(): Unit {
        let stub = StubSender()
        stub.rows = [true, true, false]
        let r = result(stub, ['Int64'])
        @Assert(r.next(), true)
        @Assert(stub.requests.size, 1)
        @Assert(stub.requests[0].index, NEXT_ROW)
        @Assert(r.next(), true)
        @Assert(r.next(), false)
        @Assert(stub.requests.size, 3)
        // 规则 4：耗尽后再调用仍返回 false 且不再发包
        @Assert(r.next(), false)
        @Assert(stub.requests.size, 3)
    }

    /** 服务端回 `ERROR(CURSOR_STATE)` → 抛 `DbdException(CURSOR_STATE)`，**不静默返回 false**（规则 2）。 */
    @TestCase
    public func cursorStateIsThrownNotSwallowed(): Unit {
        let stub = StubSender()
        stub.rows = [true]
        stub.failAt = 1
        stub.failCode = CURSOR_STATE
        let r = result(stub, ['Int64'])
        @Assert(r.next(), true)
        @Assert(codeOf { r.next() }, CURSOR_STATE)
    }

    /** `NEXT_ROW` 的响应不是 `DataBool` → `PROTOCOL`（判别的是线上报文形状，不是数值语义）。 */
    @TestCase
    public func nonBoolNextResponseIsProtocol(): Unit {
        let stub = StubSender()
        stub.rows = [true]
        stub.overrideNext = DataString('yes')
        let r = result(stub, ['Int64'])
        @Assert(codeOf { r.next() }, PROTOCOL)
    }

    /** 未 `next()` 就取列 → `CURSOR_STATE`（规则 5）；`index` 越界 → `CONVERSION` 且**不发请求**（规则 6）。 */
    @TestCase
    public func readingBeforeNextOrOutOfRange(): Unit {
        let stub = StubSender()
        stub.rows = [true]
        let r = result(stub, ['Int64'])
        @Assert(codeOf { r.get<Int64>(0) }, CURSOR_STATE)
        @Assert(stub.requests.size, 0)
        @Assert(r.next(), true)
        @Assert(codeOf { r.get<Int64>(1) }, CONVERSION)
        @Assert(codeOf { r.get<Int64>(-1) }, CONVERSION)
        @Assert(stub.requests.size, 1) // 只有那一次 NEXT_ROW
    }

    /** 取值：首次访问发 `CELL(index, 0)` 并正确转换。 */
    @TestCase
    public func getSendsCellRequestAndConverts(): Unit {
        let stub = StubSender()
        stub.rows = [true]
        stub.addCell(DataReal(42))
        let r = result(stub, ['Int64'])
        @Assert(r.next(), true)
        @Assert(r.get<Int64>(0), 42)
        @Assert(stub.requests.size, 2)
        @Assert(stub.requests[1].index, 0)
        @Assert(stub.requests[1].bufSize, 0)
    }

    /** **客户端不缓存**：同一单元格重复 `get` 重复发包（规则 8）；值由服务端当前行缓冲应答。 */
    @TestCase
    public func repeatedGetRepeatsTheRequest(): Unit {
        let stub = StubSender()
        stub.rows = [true]
        stub.addCell(DataString('a'))
        stub.addCell(DataString('a'))
        let r = result(stub, ['String'])
        @Assert(r.next(), true)
        @Assert(r.get<String>(0), 'a')
        @Assert(r.get<String>(0), 'a')
        @Assert(stub.requests.size, 3)
    }

    /** 行切换后再取同列 → 发新的 `CELL` 请求（**无行缓存**）。 */
    @TestCase
    public func rowAdvanceResendsInsteadOfCaching(): Unit {
        let stub = StubSender()
        stub.rows = [true, true, false]
        stub.addCell(DataReal(1))
        stub.addCell(DataReal(2))
        let r = result(stub, ['Int64'])
        @Assert(r.next(), true)
        @Assert(r.get<Int64>(0), 1)
        @Assert(r.next(), true)
        @Assert(r.get<Int64>(0), 2)
        @Assert(stub.requests.size, 4)
    }

    /** `getOrNull`：`DataNone`（SQL NULL）→ `None<T>`；`get<T>` 对 NULL → `CONVERSION`。 */
    @TestCase
    public func nullHandlingOfGetAndGetOrNull(): Unit {
        let stub = StubSender()
        stub.rows = [true]
        stub.addCell(DataNone.INSTANCE)
        stub.addCell(DataNone.INSTANCE)
        let r = result(stub, ['Int64'])
        @Assert(r.next(), true)
        @Assert(r.getOrNull<Int64>(0).isNone(), true)
        @Assert(codeOf { r.get<Int64>(0) }, CONVERSION)
    }

    /** 越界值 `get<Int8>(DataReal(300))` → `CONVERSION`，**不回绕**（B 口径 §3.9）。 */
    @TestCase
    public func outOfRangeValueThrowsInsteadOfWrapping(): Unit {
        let stub = StubSender()
        stub.rows = [true]
        stub.addCell(DataReal(300))
        let r = result(stub, ['Int8'])
        @Assert(r.next(), true)
        @Assert(codeOf { r.get<Int8>(0) }, CONVERSION)
    }

    /** 宽松转换保留：`get<String>` 读数值列 → `'1'`（`IGNORE_FIELD_TYPE_NOT_MATCH` 在位）。 */
    @TestCase
    public func lenientStringReadIsKept(): Unit {
        let stub = StubSender()
        stub.rows = [true]
        stub.addCell(DataReal(1))
        let r = result(stub, ['Int64'])
        @Assert(r.next(), true)
        @Assert(r.get<String>(0), '1')
    }

    /** 不支持的目标类型（普通类）→ `CONVERSION`。 */
    @TestCase
    public func unsupportedTargetTypeIsConversion(): Unit {
        let stub = StubSender()
        stub.rows = [true]
        stub.addCell(DataString('x'))
        let r = result(stub, ['String'])
        @Assert(r.next(), true)
        @Assert(codeOf { r.get<PlainValue>(0) }, CONVERSION)
    }

    /** 各类型的取值都能落地（表驱动：断言分派命中的具体分支）。 */
    @TestCase
    public func everyTypeReadsBack(): Unit {
        let stub = StubSender()
        stub.rows = [true]
        stub.addCell(true.toData())
        stub.addCell(DataReal(7))
        stub.addCell(DataString('s'))
        stub.addCell(3i8.toData())
        stub.addCell(Array<Byte>(2, { _ => 7u8 }).toData())
        stub.addCell(DataReal(1.5))
        stub.addCell(DateTime.now().toData())
        let r = result(stub, ['Bool', 'Int64', 'String', 'Int8', 'Array<Byte>', 'Float64', 'DateTime'])
        @Assert(r.next(), true)
        @Assert(r.get<Bool>(0), true)
        @Assert(r.get<Int64>(1), 7)
        @Assert(r.get<String>(2), 's')
        @Assert(r.get<Int8>(3), 3i8)
        @Assert(r.get<Array<Byte>>(4).size, 2)
        @Assert(r.get<Float64>(5), 1.5)
        @Assert(r.get<DateTime>(6).toString().isEmpty(), false)
    }

    /** T10：`Rune` 只接受单字符；多字符 / 空串 → `CONVERSION`。 */
    @TestCase
    public func runeRejectsMultiAndEmptyValues(): Unit {
        let stub = StubSender()
        stub.rows = [true]
        stub.addCell(DataString('AB'))
        stub.addCell(DataString(''))
        let r = result(stub, ['String', 'String'])
        @Assert(r.next(), true)
        @Assert(codeOf { r.get<Rune>(0) }, CONVERSION)
        @Assert(codeOf { r.get<Rune>(1) }, CONVERSION)
    }

    /** T10：块响应不是字节数组 → `CONVERSION`（不能当作 EOF 静默截断）。 */
    @TestCase
    public func undecodableStreamBlockIsConversion(): Unit {
        let stub = StubSender()
        stub.rows = [true]
        stub.overrideBlock = Some<Data>(DataDateTime(DateTime.now()))
        let r = result(stub, ['std.io.InputStream'])
        @Assert(r.next(), true)
        @Assert(codeOf { r.get<InputStream>(0) }, CONVERSION)
    }

    /** `Rune` 列按 `String` 传输并还原成单个 `Rune`（§8）。 */
    @TestCase
    public func runeColumnIsRestored(): Unit {
        let stub = StubSender()
        stub.rows = [true]
        stub.addCell(DataString('A'))
        let r = result(stub, ['String'])
        @Assert(r.next(), true)
        @Assert(r.get<Rune>(0) == r'A', true)
    }

    /** `close()`：发一次 `UNSUBSCRIBE`，桩收到的 `qid` 等于构造时给的 `queryId`（§7.3）。 */
    @TestCase
    public func closeSendsUnsubscribeWithQid(): Unit {
        let stub = StubSender()
        let r = result(stub, ['Int64'], qid: 'q-1')
        r.close()
        @Assert(stub.closes.size, 1)
        @Assert(stub.closes[0].qid, 'q-1')
        @Assert(r.isClosed(), true)
    }

    /** `close()` 幂等：第二次不再发包；之后 `next/get` → `CURSOR_STATE`。 */
    @TestCase
    public func closeIsIdempotentAndTerminates(): Unit {
        let stub = StubSender()
        stub.rows = [true]
        let r = result(stub, ['Int64'])
        r.close()
        r.close()
        @Assert(stub.closes.size, 1)
        @Assert(codeOf { r.next() }, CURSOR_STATE)
        @Assert(codeOf { r.get<Int64>(0) }, CURSOR_STATE)
    }

    /** 关闭失败（桩抛异常）仍本地关闭：异常被吞、`isClosed()` 为 `true`、已打开的流失效。 */
    @TestCase
    public func closeFailureStillReleasesLocalState(): Unit {
        let stub = StubSender()
        stub.rows = [true]
        stub.closeThrows = true
        let r = result(stub, ['std.io.InputStream'])
        @Assert(r.next(), true)
        let stream = r.get<InputStream>(0)
        r.close()
        @Assert(r.isClosed(), true)
        @Assert(codeOf { stream.read(Array<Byte>(4, repeat: 0u8)) }, CURSOR_STATE)
    }

    /** deprecated 的 `next(values)` 等价 `next()`（`values` 被忽略）。 */
    @TestCase
    public func deprecatedNextIgnoresValues(): Unit {
        let stub = StubSender()
        stub.rows = [true, false]
        let r = result(stub, ['Int64'])
        @Assert(r.next(Array<SqlDbType>()), true)
        @Assert(r.next(Array<SqlDbType>()), false)
        @Assert(stub.requests.size, 2)
    }
}

/** Step 1.10 `DbdInputStream`（设计 §3.11） */
@Test
public class DbdInputStreamTest {

    /** 3 块顺序读出：字节序与总长正确；`bufSize` 按 `chunkSize` 下发。 */
    @TestCase
    public func threeChunksReadInOrder(): Unit {
        let stub = StubSender()
        stub.rows = [true]
        stub.addBlock([1u8, 2u8, 3u8])
        stub.addBlock([4u8, 5u8, 6u8])
        stub.addBlock([7u8])
        let r = result(stub, ['std.io.InputStream'], chunkSize: 3)
        @Assert(r.next(), true)
        let stream = r.get<InputStream>(0)
        let buf = Array<Byte>(2, repeat: 0u8)
        let out = ArrayList<Byte>()
        var n = stream.read(buf)
        while (n > 0) {
            var i: Int64 = 0
            while (i < n) {
                out.add(buf[i])
                i += 1
            }
            n = stream.read(buf)
        }
        @Assert(out.size, 7)
        @Assert(out[0], 1u8)
        @Assert(out[3], 4u8)
        @Assert(out[6], 7u8)
        @Assert(stub.requests[1].bufSize, -1)   // 首次打开是 NULL 探测
        @Assert(stub.requests[2].bufSize, 3)
    }

    /** 桩返回空数组 → `read` 返回 0（EOF）；EOF 后再 `read` 仍为 0 且**不再发包**。 */
    @TestCase
    public func emptyBlockIsEofAndStopsAsking(): Unit {
        let stub = StubSender()
        stub.rows = [true]
        stub.addBlock([1u8])
        stub.addBlock([])
        let r = result(stub, ['std.io.InputStream'])
        @Assert(r.next(), true)
        let stream = r.get<InputStream>(0)
        let buf = Array<Byte>(4, repeat: 0u8)
        @Assert(stream.read(buf), 1)
        @Assert(stream.read(buf), 0)
        let before = stub.requests.size
        @Assert(stream.read(buf), 0)
        @Assert(stub.requests.size, before)
    }

    /** 目标 buffer 小于块时，余量留到下次（不丢字节）。 */
    @TestCase
    public func leftoverIsKeptForNextRead(): Unit {
        let stub = StubSender()
        stub.rows = [true]
        stub.addBlock([1u8, 2u8, 3u8, 4u8])
        let r = result(stub, ['std.io.InputStream'], chunkSize: 4)
        @Assert(r.next(), true)
        let stream = r.get<InputStream>(0)
        let small = Array<Byte>(1, repeat: 0u8)
        @Assert(stream.read(small), 1)
        @Assert(small[0], 1u8)
        @Assert(stream.read(small), 1)
        @Assert(small[0], 2u8)
        @Assert(stub.requests.size, 2) // NEXT_ROW + NULL 探测（首块已随探测返回）
    }

    /** 短块**不是** EOF：一次 `read` 未读满块后，下次 `read` 会继续取下一块。 */
    @TestCase
    public func shortBlockIsNotEof(): Unit {
        let stub = StubSender()
        stub.rows = [true]
        stub.addBlock([1u8])
        stub.addBlock([2u8])
        stub.addBlock([])
        let r = result(stub, ['std.io.InputStream'])
        @Assert(r.next(), true)
        let stream = r.get<InputStream>(0)
        let buf = Array<Byte>(4, repeat: 0u8)
        @Assert(stream.read(buf), 1)
        @Assert(stream.read(buf), 1)
        @Assert(buf[0], 2u8)
        @Assert(stream.read(buf), 0)
    }

    /** 规则 1：`next()` 后旧流 `read` → `CURSOR_STATE`。 */
    @TestCase
    public func streamDiesOnRowAdvance(): Unit {
        let stub = StubSender()
        stub.rows = [true, true, false]
        stub.addBlock([1u8])
        let r = result(stub, ['std.io.InputStream'])
        @Assert(r.next(), true)
        let stream = r.get<InputStream>(0)
        @Assert(stream.read(Array<Byte>(4, repeat: 0u8)), 1)
        @Assert(r.next(), true)
        @Assert(codeOf { stream.read(Array<Byte>(4, repeat: 0u8)) }, CURSOR_STATE)
    }

    /** 同一行同一列重复 `get<InputStream>` 返回**同一个**句柄（避免两个流交错消耗服务端那一个流）。 */
    @TestCase
    public func sameRowSameColumnSharesOneHandle(): Unit {
        let stub = StubSender()
        stub.rows = [true]
        stub.addBlock([1u8, 2u8])
        let r = result(stub, ['std.io.InputStream'])
        @Assert(r.next(), true)
        let a = r.get<InputStream>(0)
        let b = r.get<InputStream>(0)
        let buf = Array<Byte>(1, repeat: 0u8)
        @Assert(a.read(buf), 1)
        @Assert(b.read(buf), 1)
        @Assert(buf[0], 2u8)
    }

    /** G04：NULL 流列 → `getOrNull<InputStream>` 返回 `None`，`get` 抛 `CONVERSION`。 */
    @TestCase
    public func nullStreamYieldsNone(): Unit {
        let stub = StubSender()
        stub.rows = [true]
        stub.nullProbe = true
        let r = result(stub, ['std.io.InputStream'])
        @Assert(r.next(), true)
        @Assert(r.getOrNull<InputStream>(0).isNone(), true)
        @Assert(codeOf { r.get<InputStream>(0) }, CONVERSION)
        // 只有 NEXT_ROW + 一次探测，没有额外的块请求
        @Assert(stub.requests.size, 2)
        @Assert(stub.requests[1].bufSize, -1)
    }

    /** G04：空 BLOB（服务端回空块）与 NULL 可区分：前者是 `Some(空流)`。 */
    @TestCase
    public func emptyBlobIsSomeEmptyStream(): Unit {
        let stub = StubSender()
        stub.rows = [true]
        stub.addBlock([])
        let r = result(stub, ['std.io.InputStream'])
        @Assert(r.next(), true)
        let opened = r.getOrNull<InputStream>(0)
        @Assert(opened.isSome(), true)
        @Assert(opened.getOrThrow().read(Array<Byte>(4, repeat: 0u8)), 0)
    }

    /** G04 兼容：旧服务端把 `-1` 当 `<=0` 返回首块（NULL 时为空数组）→ 退化为空流而不报错。 */
    @TestCase
    public func probeIsBackwardCompatibleWithOldServer(): Unit {
        let stub = StubSender()
        stub.rows = [true]
        stub.addBlock([])
        let r = result(stub, ['std.io.InputStream'])
        @Assert(r.next(), true)
        let opened = r.getOrNull<InputStream>(0)
        @Assert(opened.isSome(), true)
        @Assert(opened.getOrThrow().read(Array<Byte>(4, repeat: 0u8)), 0)
    }

    /** G05：流列按标量读取 → `CONVERSION`，且**不发**列读请求。 */
    @TestCase
    public func scalarReadOfStreamColumnIsRejected(): Unit {
        let stub = StubSender()
        stub.rows = [true]
        stub.addBlock([1u8])
        let r = result(stub, ['std.io.InputStream'])
        @Assert(r.next(), true)
        @Assert(codeOf { r.get<Array<Byte>>(0) }, CONVERSION)
        @Assert(codeOf { r.get<String>(0) }, CONVERSION)
        @Assert(stub.requests.size, 1)   // 只有 NEXT_ROW
    }

    /** 非流列上 `get<InputStream>` → `CONVERSION`（列类型不符）。 */
    @TestCase
    public func streamRequestOnNonStreamColumn(): Unit {
        let stub = StubSender()
        stub.rows = [true]
        stub.addCell(DataString('x'))
        let r = result(stub, ['String'])
        @Assert(r.next(), true)
        @Assert(codeOf { r.get<InputStream>(0) }, CONVERSION)
    }

    /**
     * 接口实现类作 `T` 时走兜底（§10.1 结论 3：B 的精确匹配认不出实现类，必须补子类型判定）。
     *
     * 兜底**确实命中了流列分支**（报错是"列不是流列 / 无法转成该实现类"，而不是"不支持的类型"）；
     * 最终仍抛 `CONVERSION` —— 因为 `DbdInputStream` 无法作为任意 `InputStream` 实现类返回，
     * 这与候选 A 在同一场景下的结果一致。
     */
    @TestCase
    public func interfaceImplementorUsesSubtypeFallback(): Unit {
        let stub = StubSender()
        stub.rows = [true]
        stub.addBlock([9u8])
        let r = result(stub, ['std.io.InputStream'])
        @Assert(r.next(), true)
        let onStreamColumn = messageOf { r.get<MyStreamImpl>(0) }
        @Assert(onStreamColumn.contains('unsupported column type'), false)
        @Assert(onStreamColumn.contains('cannot be read as'), true)

        let plain = StubSender()
        plain.rows = [true]
        plain.addCell(DataString('x'))
        let r2 = result(plain, ['String'])
        @Assert(r2.next(), true)
        // 兜底命中接口后仍要校验列类型：非流列 → "不是流列"，而不是"不支持的类型"
        @Assert(messageOf { r2.get<MyStreamImpl>(0) }.contains('not a stream column'), true)
    }

    /** `chunkSize` 缺省 = `DEFAULT_STREAM_CHUNK`。 */
    @TestCase
    public func defaultChunkSize(): Unit {
        let stub = StubSender()
        stub.rows = [true]
        stub.addBlock([1u8])
        let r = result(stub, ['std.io.InputStream'])
        @Assert(r.next(), true)
        let stream = r.get<InputStream>(0)
        // 首块随 NULL 探测返回；消费完后才会带 chunkSize 发下一次块请求（此处桩回空 → EOF）
        @Assert(stream.read(Array<Byte>(1, repeat: 0u8)), 1)
        @Assert(stream.read(Array<Byte>(1, repeat: 0u8)), 0)
        @Assert(stub.requests[1].bufSize, -1)
        @Assert(stub.requests[2].bufSize, DEFAULT_STREAM_CHUNK)
    }
}

/** 一个不支持的目标类型（普通类）。 */
private class PlainValue {}

/** `InputStream` 的实现类：用来验证 §10.1 结论 3 的接口子类型兜底。 */
private class MyStreamImpl <: InputStream {
    public func read(_: Array<Byte>): Int64 {
        0
    }
}

/**
 * 桩发送器：脚本化 `NEXT_ROW` / `CELL` 的响应，并记录收到的载荷。
 *
 * `cells` / `blocks` 按消费顺序取用；`rows` 供 `NEXT_ROW` 依次应答；`failAt` 指定第几个请求抛异常。
 */
class StubSender {
    var rows: Array<Bool> = []
    var requests: ArrayList<QueryResultColumnPayload> = ArrayList<QueryResultColumnPayload>()
    var closes: ArrayList<QueryResultClosePayload> = ArrayList<QueryResultClosePayload>()
    /** 第几个请求（0 起）抛 `DbdException(failCode)`；`-1` 表示不抛。 */
    var failAt: Int64 = -1
    var failCode: DbdErrorCode = CURSOR_STATE
    /** 非 `None` 时覆盖 `NEXT_ROW` 的应答（用于"响应形状不对"的负例）。 */
    var overrideNext: ?Data = None<Data>
    var closeThrows: Bool = false
    /** `true` 时 NULL 探测（`bufSize < 0`）返回 `DataNone`（模拟 SQL NULL 流列）。 */
    var nullProbe: Bool = false
    /** 非 `None` 时覆盖块应答（用于"块不是字节"的负例）。 */
    var overrideBlock: ?Data = None<Data>
    private let cells = ArrayList<Data>()
    private let blocks = ArrayList<Array<Byte>>()
    private var rowCursor: Int64 = 0
    private var cellCursor: Int64 = 0
    private var blockCursor: Int64 = 0

    /** 排一个单元格（`CELL(index, 0)`）的应答。 */
    func addCell(data: Data): Unit {
        cells.add(data)
    }

    /** 排一个块（`CELL(index, chunkSize)`）的应答；空数组表示 EOF。 */
    func addBlock(bytes: Array<Byte>): Unit {
        blocks.add(bytes)
    }

    func send(payload: QueryResultColumnPayload): Data {
        requests.add(payload)
        if (failAt >= 0 && requests.size - 1 == failAt) {
            throw DbdException(failCode, 'stub failure')
        }
        if (payload.index == NEXT_ROW) {
            if (let Some(d) <- overrideNext) {
                return d
            }
            let has = if (rowCursor < rows.size) { rows[rowCursor] } else { false }
            rowCursor += 1
            return has.toData()
        }
        if (payload.bufSize != 0) {
            if (let Some(d) <- overrideBlock) {
                return d
            }
            if (payload.bufSize < 0 && nullProbe) {
                return DataNone.INSTANCE
            }
            let block = if (blockCursor < blocks.size) { blocks[blockCursor] } else { Array<Byte>() }
            blockCursor += 1
            return block.toData()
        }
        let cell = if (cellCursor < cells.size) { cells[cellCursor] } else { DataNone.INSTANCE }
        cellCursor += 1
        cell
    }

    func close(payload: QueryResultClosePayload): Unit {
        closes.add(payload)
        if (closeThrows) {
            throw DbdException(IO, 'unsubscribe failed')
        }
    }
}

/** 用桩构造一个结果集（`typeNames` 逐列给出仓颉类型名）。 */
func result(stub: StubSender, typeNames: Array<String>, qid!: String = 'q-0',
    chunkSize!: Int64 = 0): QueryResultImpl {
    let infos = ArrayList<ColumnInfoImpl>()
    for (i in 0..typeNames.size) {
        infos.add(ColumnInfoImpl('c${i}', typeNames[i], 20, 0, false, 21))
    }
    QueryResultImpl(QueryResultServerPayload(infos.toArray()), qid, stub.send, closer: stub.close,
        chunkSize: chunkSize)
}

/** 执行 `body` 并回其抛出的 `DbdException.code`；没抛或抛的不是 `DbdException` 时返回 `INTERNAL`。 */
private func codeOf<T>(body: () -> T): DbdErrorCode {
    try {
        body()
    } catch (e: DbdException) {
        return e.code
    } catch (_: Exception) {
        return INTERNAL
    }
    INTERNAL
}

/** 执行 `body` 并回其抛出的异常消息；没抛返回 `''`（用于区分兜底是否命中）。 */
private func messageOf<T>(body: () -> T): String {
    try {
        body()
    } catch (e: DbdException) {
        return e.toString()
    } catch (e: Exception) {
        return e.toString()
    }
    ''
}

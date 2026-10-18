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
package fountain::fdbm.execute

import std.collection.{ArrayList, HashMap}
import std.database.sql.*
import std.io.InputStream
import fountain::f_data.{Data, DataNone, DataString}
import fountain::f_data.base.*
import fountain::f_dbd.common.{ColumnInfoImpl, DbdErrorCode, DEFAULT_STREAM_CHUNK, SqlTypes}
import fountain::fdbm.exception.FdbmException

/** 一个物理库上的结果集段（设计 §9.1）；段关闭时归还连接（pin 的连接除外）。 */
protected class CursorSegment <: Resource {
    public let statement: Statement
    public let result: QueryResult
    public let connection: Connection
    private let ownsConnection: Bool
    private var closed: Bool = false

    public init(statement: Statement, result: QueryResult, connection: Connection,
        ownsConnection!: Bool = true) {
        this.statement = statement
        this.result = result
        this.connection = connection
        this.ownsConnection = ownsConnection
    }

    public func close(): Unit {
        if (closed) {
            return
        }
        closed = true
        try {
            result.close()
        } catch (_: Exception) {
            ()
        }
        try {
            statement.close()
        } catch (_: Exception) {
            ()
        }
        if (ownsConnection) {
            try {
                connection.close()
            } catch (_: Exception) {
                ()
            }
        }
    }

    public func isClosed(): Bool {
        closed
    }
}

/**
 * 服务端游标（设计 §9.1）：无预读、当前行缓冲、多段按库序串联。
 *
 * `qid` 由 server 层在创建后写入（= 查询 CONSUME 的 `Message.id`），用于 `UNSUBSCRIBE` 匹配。
 */
protected class QueryCursor <: Resource {
    public var qid: String = ''
    private let segments: Array<CursorSegment>
    private let infos: Array<ColumnInfoImpl>
    private let empty: Bool
    private let memory: ?QueryResult
    private var segmentIndex: Int64 = 0
    private var rowValid: Bool = false
    private var closed: Bool = false
    private let cells = HashMap<Int64, Data>()
    private let streams = HashMap<Int64, InputStream>()

    public init(segments: Array<CursorSegment>, infos: Array<ColumnInfoImpl>, empty!: Bool = false,
        memory!: ?QueryResult = None) {
        this.segments = segments
        this.infos = infos
        this.empty = empty
        this.memory = memory
    }

    /** 无结果集（`Empty` 路由 / SHOW 的内存结果）的列信息。 */
    public static func columnsOf(result: QueryResult): Array<ColumnInfoImpl> {
        let list = ArrayList<ColumnInfoImpl>()
        for (info in result.columnInfos) {
            list.add(ColumnInfoImpl(info.name, SqlTypes.canonicalName(info.typeName),
                info.length, info.scale, info.nullable, info.displaySize))
        }
        list.toArray()
    }

    public prop columnInfos: Array<ColumnInfoImpl> {
        get() {
            infos
        }
    }

    public func next(): Bool {
        if (closed) {
            throw FdbmException(DbdErrorCode.CURSOR_STATE, 'query cursor ${qid} is closed')
        }
        if (empty) {
            return false
        }
        match (memory) {
            case Some(result) =>
                clearRow()
                rowValid = result.next()
                return rowValid
            case None => ()
        }
        while (segmentIndex < segments.size) {
            let segment = segments[segmentIndex]
            if (segment.result.next()) {
                clearRow()
                rowValid = true
                return true
            }
            segment.close()
            segmentIndex += 1
        }
        rowValid = false
        clearRow()
        false
    }

    /** 读一格：命中缓冲直接返回；流列按块读（句柄每行每列只打开一次）。 */
    public func cell(index: Int64, bufSize: Int64): Data {
        if (closed) {
            throw FdbmException(DbdErrorCode.CURSOR_STATE, 'query cursor ${qid} is closed')
        }
        if (!rowValid) {
            throw FdbmException(DbdErrorCode.CURSOR_STATE,
                'no current row on query cursor ${qid}: invoke NEXT_ROW before reading columns')
        }
        if (index < 0 || index >= infos.size) {
            throw FdbmException(DbdErrorCode.CONVERSION,
                'column index ${index} is out of range [0, ${infos.size})')
        }
        let typeName = infos[index].typeName
        if (typeName == 'InputStream' || typeName == 'std.io.InputStream') {
            let stream = match (streams.get(index)) {
                case Some(existing) => existing
                case None =>
                    let opened = SqlTypes.readStream(currentResult(), index)
                    streams[index] = opened
                    opened
            }
            let size = if (bufSize <= 0) { DEFAULT_STREAM_CHUNK } else { bufSize }
            return SqlTypes.readChunk(stream, size).toData()
        }
        match (cells.get(index)) {
            case Some(cached) => cached
            case None =>
                let data = SqlTypes.readData(currentResult(), index, typeName)
                cells[index] = data
                data
        }
    }

    public func close(): Unit {
        if (closed) {
            return
        }
        closed = true
        rowValid = false
        clearRow()
        while (segmentIndex < segments.size) {
            segments[segmentIndex].close()
            segmentIndex += 1
        }
    }

    /**
     * 关闭握手用（设计 §10.2）：清空当前行缓冲 → 读尽物理结果集 → 关闭全部段并归还连接。
     *
     * 读尽是为了让物理驱动完整走完结果集再回收连接（服务端不把"未读完"的连接放回池里）。
     * 中途异常由调用方记录，但 `close()` 一定执行。
     */
    public func drain(): Unit {
        if (closed) {
            return
        }
        clearRow()
        try {
            while (next()) {
                // 只为读尽，不保留任何行
            }
        } finally {
            close()
        }
    }

    public func isClosed(): Bool {
        closed
    }

    private func currentResult(): QueryResult {
        match (memory) {
            case Some(result) => result
            case None => segments[segmentIndex].result
        }
    }

    private func clearRow(): Unit {
        cells.clear()
        streams.clear()
        rowValid = false
    }
}

/** 内存结果集（SHOW / 空结果）：把已构造好的行喂给同一个游标通道。 */
protected class MemoryQueryResult <: QueryResult {
    private let columns: Array<ColumnInfo>
    private let rows: Array<Array<Data>>
    private var rowIndex: Int64 = -1
    private var closed: Bool = false

    public init(columns: Array<ColumnInfo>, rows: Array<Array<Data>>) {
        this.columns = columns
        this.rows = rows
    }

    public prop columnInfos: Array<ColumnInfo> {
        get() {
            columns
        }
    }

    public func next(): Bool {
        rowIndex += 1
        rowIndex < rows.size
    }

    public func next(_: Array<SqlDbType>): Bool {
        next()
    }

    public func get<T>(index: Int64): T {
        match (getOrNull<T>(index)) {
            case Some(value) => value
            case None => throw FdbmException(DbdErrorCode.CONVERSION,
                'column ${index} is NULL')
        }
    }

    public func getOrNull<T>(index: Int64): ?T {
        if (rowIndex < 0 || rowIndex >= rows.size) {
            throw FdbmException(DbdErrorCode.CURSOR_STATE, 'row is not ready')
        }
        let row = rows[rowIndex]
        if (index < 0 || index >= row.size) {
            throw FdbmException(DbdErrorCode.CONVERSION, 'column ${index} is out of range')
        }
        let data = row[index]
        if (data is DataNone) {
            return None<T>
        }
        match (data) {
            case text: DataString =>
                match (text.data) {
                    case value: T => return Some(value)
                    case _ => throw FdbmException(DbdErrorCode.CONVERSION,
                        'column ${index} cannot be read as ${TypeInfo.of<T>()}')
                }
            case _ => throw FdbmException(DbdErrorCode.CONVERSION,
                'column ${index} cannot be read as ${TypeInfo.of<T>()}')
        }
    }

    public func close(): Unit {
        closed = true
    }

    public func isClosed(): Bool {
        closed
    }
}

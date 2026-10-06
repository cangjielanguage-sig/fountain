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
package fountain::f_orm.wrap

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.ArrayList
import std.database.sql.*

/** 记录「有没有被关」的流：ORM-C6 的反向风险护栏用 */
private class RecordingInputStream <: InputStream {
    var closed = false
    public func read(buffer: Array<Byte>): Int64 {
        0
    }
    public func close(): Unit {
        closed = true
    }
}

/** 只记录 `set` 调用的语句桩（本用例只关心"流有没有被交给驱动"） */
private class RecordingStatement <: Statement {
    let sets = ArrayList<String>()
    public prop parameterColumnInfos: Array<ColumnInfo> {
        get() {
            []
        }
    }
    public func query(params: Array<SqlDbType>): QueryResult {
        throw ConnectionException('recording statement: query(params) is not supported')
    }
    public func setOption(key: String, value: String): Unit {}
    public func update(params: Array<SqlDbType>): UpdateResult {
        throw ConnectionException('recording statement: update(params) is not supported')
    }
    public func set<T>(index: Int64, value: T): Unit {
        sets.add('set<${TypeInfo.of<T>()}>(${index})')
    }
    public func setNull(index: Int64): Unit {
        sets.add('setNull(${index})')
    }
    public func update(): UpdateResult {
        throw ConnectionException('recording statement: update() is not supported')
    }
    public func query(): QueryResult {
        throw ConnectionException('recording statement: query() is not supported')
    }
    public func isClosed(): Bool {
        false
    }
    public func close(): Unit {}
}

/**
 * bug-orm.md §3.2 `ORM-C6` 的**反向风险**护栏：ORM 不得关闭调用方传进来的流。
 *
 * 背景：条目的正文是"模块内不关闭流"；但反过来"顺手补一个 `close()`"是更危险的方向——
 * `StringReader.close()` 会关底层流（std 文档），`InputStreamSqlArg` 代关则会关掉调用方还要用的资源。
 * 这条用例把「只转交、不关闭」钉住：若有人后来在 `InputStreamSqlArg.set` 里加了 close，它会直接红。
 */
@Test
public class InputStreamOwnershipTest {
    @TestCase
    public func testCallerStreamIsHandedOverButNotClosed(): Unit {
        let stream = RecordingInputStream()
        let args = SqlArgs()
        args.add(stream)
        let recorder = RecordingStatement()
        args.set(recorder)
        @Assert(false, stream.closed)                       // 不得关闭调用方的流
        @Assert(1, recorder.sets.size)                      // 但必须交给驱动一次
        @Assert(true, recorder.sets[0].contains('InputStream'))
    }
}

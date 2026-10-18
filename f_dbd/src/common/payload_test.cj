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

import std.collection.ArrayList
import std.database.sql.*
import std.io.ByteBuffer
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_codec.default.DefaultCodec
import fountain::f_data.base.*

/** Step 1.1–1.4 与 §3.6.1 的共用载荷（设计 §3.3–§3.6.1） */
@Test
public class PayloadTest {

    private func roundTrip<T>(p: T): T where T <: DataFields<T> {
        let buf = ByteBuffer()
        DefaultCodec().encode<T>(p).finish().copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        match (DefaultCodec().decode<T>(buf)) {
            case Some(x) => x
            case _ => throw Exception('decode failed')
        }
    }

    private func keysOfUpdateResult(p: UpdateResultPayload): ArrayList<String> {
        let obj = (p.toData() as DataObject<UpdateResultPayload>).getOrThrow()
        let keys = ArrayList<String>()
        for ((k, _) in obj) {
            keys.add(k)
        }
        keys
    }

    private func keysOfServer(p: QueryResultServerPayload): ArrayList<String> {
        let obj = (p.toData() as DataObject<QueryResultServerPayload>).getOrThrow()
        let keys = ArrayList<String>()
        for ((k, _) in obj) {
            keys.add(k)
        }
        keys
    }

    // ========== Step 1.1 SqlPayload ==========

    @TestCase
    public func sqlPayloadDefaults(): Unit {
        let p = SqlPayload()
        @Assert(p.sql, '')
        @Assert(p.params.size, 0)
    }

    @TestCase
    public func sqlPayloadSqlConstructor(): Unit {
        let p = SqlPayload('select 1')
        @Assert(p.sql, 'select 1')
        @Assert(p.params.size, 0)
    }

    @TestCase
    public func sqlPayloadAdd(): Unit {
        let p = SqlPayload('select * from t where a=? and b=?')
        p.add<String>('a')
        p.add<Int64>(1)
        @Assert(p.params.size, 2)
        @Assert(p.params[0].data.toString(), DataAny(DataString('a')).data.toString())
        @Assert(p.params[1].data.toString(), DataAny(DataReal(1)).data.toString())
    }

    @TestCase
    public func sqlPayloadAddNull(): Unit {
        let p = SqlPayload()
        p.addNull()
        @Assert(p.params.size, 1)
        @Assert(p.params[0].data is DataNone)
    }

    /** "params 必须 var" 的回归：写成 let 时解码会静默丢参数（个数为 0）。 */
    @TestCase
    public func sqlPayloadRoundTripKeepsParams(): Unit {
        let p = SqlPayload('select * from t where a=? and b=?')
        p.add<String>('a')
        p.add<Int64>(1)
        let back = roundTrip<SqlPayload>(p)
        @Assert(back.sql, 'select * from t where a=? and b=?')
        @Assert(back.params.size, 2)
        @Assert(back.params[0].data.toString(), 'a')
    }

    // ========== Step 1.2 UpdateResultPayload ==========

    @TestCase
    public func updateResultPayloadDefaults(): Unit {
        let u = UpdateResultPayload()
        @Assert(u.rc, 0)
        @Assert(u.liid, 0)
        @Assert(u.rowCount, 0)
        @Assert(u.lastInsertId, 0)
    }

    @TestCase
    public func updateResultPayloadFullConstructor(): Unit {
        let u = UpdateResultPayload(3, 7)
        @Assert(u.rc, 3)
        @Assert(u.liid, 7)
        @Assert(u.rowCount, 3)
        @Assert(u.lastInsertId, 7)
    }

    /** `@DataExclude[field]` 的回归：排除失效会多出 `rowCount`/`lastInsertId` 两个只读键。 */
    @TestCase
    public func updateResultWireKeysAreExactlyRcAndLiid(): Unit {
        let keys = keysOfUpdateResult(UpdateResultPayload(3, 7))
        @Assert(keys.size, 2)
        @Assert(keys.contains('rc'))
        @Assert(keys.contains('liid'))
        @Assert(!keys.contains('rowCount'))
        @Assert(!keys.contains('lastInsertId'))
    }

    @TestCase
    public func updateResultImplementsUpdateResult(): Unit {
        let r: UpdateResult = UpdateResultPayload(3, 7)
        @Assert(r.rowCount, 3)
        @Assert(r.lastInsertId, 7)
    }

    @TestCase
    public func updateResultRoundTripAndStrictDecode(): Unit {
        let back = roundTrip<UpdateResultPayload>(UpdateResultPayload(3, 7))
        @Assert(back.rowCount, 3)
        @Assert(back.lastInsertId, 7)
        let strict = decodeStrict<UpdateResultPayload>(UpdateResultPayload(3, 7).toData())
        @Assert(strict.isSome())
        @Assert(strict.getOrThrow().rowCount, 3)
    }

    // ========== Step 1.3 QueryResultServerPayload（仅列信息，无 hasData） ==========

    @TestCase
    public func queryResultServerPayloadDefaults(): Unit {
        let q = QueryResultServerPayload()
        @Assert(q.columnInfos.size, 0)
    }

    @TestCase
    public func queryResultServerPayloadColumnInfos(): Unit {
        let q = QueryResultServerPayload([ColumnInfoImpl('id', 'Int64', 20, 0, false, 21),
            ColumnInfoImpl('nm', 'String', 64, 0, true, 65)])
        @Assert(q.columnInfos.size, 2)
        @Assert(q.columnInfos[0].name, 'id')
        @Assert(q.columnInfos[1].name, 'nm')
    }

    /** 无行状态：线上键集合恰好是 `{columnInfos}`，没有任何 hasData 类字段。 */
    @TestCase
    public func queryResultServerPayloadHasNoRowState(): Unit {
        let keys = keysOfServer(
            QueryResultServerPayload([ColumnInfoImpl('id', 'Int64', 20, 0, false, 21)]))
        @Assert(keys.size, 1)
        @Assert(keys.contains('columnInfos'))
    }

    @TestCase
    public func queryResultServerPayloadRoundTrip(): Unit {
        let q = QueryResultServerPayload([ColumnInfoImpl('id', 'Int64', 20, 0, false, 21),
            ColumnInfoImpl('nm', 'String', 64, 0, true, 65)])
        let back = roundTrip<QueryResultServerPayload>(q)
        @Assert(back.columnInfos.size, 2)
        @Assert(back.columnInfos[1].typeName, 'String')
    }

    /** 空列信息（0 行结果集）也能构造且往返一致。 */
    @TestCase
    public func queryResultServerPayloadEmptyColumnInfos(): Unit {
        let back = roundTrip<QueryResultServerPayload>(QueryResultServerPayload([]))
        @Assert(back.columnInfos.size, 0)
    }

    // ========== Step 1.4 QueryResultColumnPayload 与常量 ==========

    @TestCase
    public func queryResultColumnPayloadDefaults(): Unit {
        let c = QueryResultColumnPayload()
        @Assert(c.index, 0)
        @Assert(c.bufSize, 0)
    }

    @TestCase
    public func queryResultColumnPayloadFullConstructor(): Unit {
        let c = QueryResultColumnPayload(3, bufSize: 64)
        @Assert(c.index, 3)
        @Assert(c.bufSize, 64)
    }

    @TestCase
    public func queryResultColumnPayloadFactories(): Unit {
        @Assert(QueryResultColumnPayload.cell(2).index, 2)
        @Assert(QueryResultColumnPayload.cell(2).bufSize, 0)
        @Assert(QueryResultColumnPayload.cell(2, bufSize: 9).bufSize, 9)
        @Assert(QueryResultColumnPayload.nextRow().index, NEXT_ROW)
        @Assert(QueryResultColumnPayload.nextRow().bufSize, 0)
    }

    @TestCase
    public func topLevelConstants(): Unit {
        @Assert(NEXT_ROW, -1)
        @Assert(DEFAULT_PORT, 8112)
        @Assert(DEFAULT_STREAM_CHUNK, 65536)
        @Assert(CELL_READ_FLAG, THROWING_ON_INT_OVERFLOW | IGNORE_FIELD_TYPE_NOT_MATCH)
        // B 口径的回归红线：不得含回绕位，也不得含 IGNORE_FIELD_NOT_CONVERTABLE
        @Assert((CELL_READ_FLAG & WRAPPING_ON_INT_OVERFLOW) == 0)
        @Assert((CELL_READ_FLAG & IGNORE_FIELD_NOT_CONVERTABLE) == 0)
        @Assert((CELL_READ_FLAG & SATURATING_ON_INT_OVERFLOW) == 0)
    }

    // ========== §3.6.1 QueryResultClosePayload ==========

    @TestCase
    public func queryResultClosePayloadDefaults(): Unit {
        @Assert(QueryResultClosePayload().qid, '')
    }

    @TestCase
    public func queryResultClosePayloadRoundTrip(): Unit {
        let back = roundTrip<QueryResultClosePayload>(QueryResultClosePayload('abc-123'))
        @Assert(back.qid, 'abc-123')
    }
}

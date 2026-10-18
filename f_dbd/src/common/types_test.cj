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
import fountain::f_data.base.*

/** Step 1.7 `decodeStrict<T>`（设计 §3.2） */
@Test
public class DecodeStrictTest {

    /** 四类含整数字段的载荷都必须能严格解出（flag: 0 时整数解不出来，这是本用例的关键）。 */
    @TestCase
    public func strictDecodesEachPayloadKind(): Unit {
        let sql = SqlPayload('select 1')
        sql.add<Int64>(1)
        @Assert(decodeStrict<SqlPayload>(sql.toData()).isSome())
        @Assert(decodeStrict<QueryResultColumnPayload>(
            QueryResultColumnPayload(3, bufSize: 64).toData()).isSome())
        @Assert(decodeStrict<QueryResultServerPayload>(
            QueryResultServerPayload([ColumnInfoImpl('id', 'Int64', 20, 0, false, 21)]).toData()).isSome())
        @Assert(decodeStrict<UpdateResultPayload>(UpdateResultPayload(3, 7).toData()).isSome())
        @Assert(decodeStrict<DbdErrorPayload>(DbdErrorPayload(TIMEOUT, 't').toData()).isSome())
    }

    /** 交叉喂入：互相不命中，返回 None（不抛异常、不产出"字段为空的同形对象"）。 */
    @TestCase
    public func crossFeedingMisses(): Unit {
        let sql = SqlPayload('select 1')
        let col = QueryResultColumnPayload(3, bufSize: 64)
        let upd = UpdateResultPayload(3, 7)
        let srv = QueryResultServerPayload([ColumnInfoImpl('id', 'Int64', 20, 0, false, 21)])
        @Assert(decodeStrict<QueryResultColumnPayload>(sql.toData()).isNone())
        @Assert(decodeStrict<SqlPayload>(col.toData()).isNone())
        @Assert(decodeStrict<UpdateResultPayload>(sql.toData()).isNone())
        @Assert(decodeStrict<SqlPayload>(upd.toData()).isNone())
        @Assert(decodeStrict<QueryResultServerPayload>(col.toData()).isNone())
        @Assert(decodeStrict<QueryResultColumnPayload>(srv.toData()).isNone())
        @Assert(decodeStrict<DbdErrorPayload>(upd.toData()).isNone())
    }

    @TestCase
    public func dataNoneAndDataAny(): Unit {
        @Assert(decodeStrict<SqlPayload>(DataNone.INSTANCE).isNone())
        let sql = SqlPayload('select 1')
        @Assert(decodeStrict<SqlPayload>(DataAny(sql.toData())).isSome())
    }

    /**
     * 结构合法但数值越界仍算命中（WRAPPING 语义），且**不抛出 OverflowException**：
     * 判别只由结构决定，数值语义交由取值侧的 B 口径（CELL_READ_FLAG）处理。
     */
    @TestCase
    public func outOfRangeValueStillHits(): Unit {
        let p = UpdateResultPayload(0, 0)
        p.rc = Int64.Max
        let hit = decodeStrict<UpdateResultPayload>(p.toData())
        @Assert(hit.isSome())
        @Assert(hit.getOrThrow().rc, Int64.Max)
    }
}

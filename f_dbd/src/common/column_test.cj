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

/** Step 1.5 `ColumnInfoImpl`（设计 §3.7） */
@Test
public class ColumnInfoImplTest {

    private func roundTrip(c: ColumnInfoImpl): ColumnInfoImpl {
        let buf = ByteBuffer()
        DefaultCodec().encode(c).finish().copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        let decoded = DefaultCodec().decode<ColumnInfoImpl>(buf)
        match (decoded) {
            case Some(x) => x
            case _ => throw Exception('decode<ColumnInfoImpl> failed')
        }
    }

    @TestCase
    public func defaultValues(): Unit {
        let c = ColumnInfoImpl()
        @Assert(c.name, '')
        @Assert(c.typeName, '')
        @Assert(c.length, 0)
        @Assert(c.scale, 0)
        @Assert(c.nullable, false)
        @Assert(c.displaySize, 0)
    }

    @TestCase
    public func fullConstructor(): Unit {
        let c = ColumnInfoImpl('id', 'Int64', 20, 0, false, 21)
        @Assert(c.name, 'id')
        @Assert(c.typeName, 'Int64')
        @Assert(c.length, 20)
        @Assert(c.scale, 0)
        @Assert(c.nullable, false)
        @Assert(c.displaySize, 21)
    }

    /** 数据字段（短名）可读可写。 */
    @TestCase
    public func shortNameFieldsAreMutable(): Unit {
        let c = ColumnInfoImpl('id', 'Int64', 20, 0, false, 21)
        @Assert(c.nm, 'id')
        @Assert(c.tn, 'Int64')
        @Assert(c.len, 20)
        @Assert(c.scl, 0)
        @Assert(c.nl, false)
        @Assert(c.ds, 21)
        c.nm = 'uid'
        c.tn = 'String'
        c.len = 8
        c.scl = 2
        c.nl = true
        c.ds = 9
        @Assert(c.name, 'uid')
        @Assert(c.typeName, 'String')
        @Assert(c.length, 8)
        @Assert(c.scale, 2)
        @Assert(c.nullable, true)
        @Assert(c.displaySize, 9)
    }

    /**
     * 线上键集合**恰好**是 `{nm, tn, len, scl, nl, ds}` 且一个不多：
     * 这条钉住 6 个 `@DataExclude[field]`（排除失效会多出 `name`/`typeName`/… 6 个只读键，
     * 严格解码会判"找不到可变字段"）。
     */
    @TestCase
    public func wireKeysAreExactlyTheSixShortNames(): Unit {
        let c = ColumnInfoImpl('id', 'Int64', 20, 0, false, 21)
        let obj = (c.toData() as DataObject<ColumnInfoImpl>).getOrThrow()
        let keys = ArrayList<String>()
        for ((k, _) in obj) {
            keys.add(k)
        }
        @Assert(keys.size, 6)
        @Assert(keys.contains('nm'))
        @Assert(keys.contains('tn'))
        @Assert(keys.contains('len'))
        @Assert(keys.contains('scl'))
        @Assert(keys.contains('nl'))
        @Assert(keys.contains('ds'))
        @Assert(!keys.contains('name'))
        @Assert(!keys.contains('typeName'))
        @Assert(!keys.contains('length'))
        @Assert(!keys.contains('scale'))
        @Assert(!keys.contains('nullable'))
        @Assert(!keys.contains('displaySize'))
    }

    /** 直接实现 `ColumnInfo`，无适配器类。 */
    @TestCase
    public func implementsColumnInfo(): Unit {
        let c: ColumnInfo = ColumnInfoImpl('id', 'Int64', 20, 0, false, 21)
        @Assert(c.name, 'id')
        @Assert(c.typeName, 'Int64')
        @Assert(c.length, 20)
        @Assert(c.scale, 0)
        @Assert(c.nullable, false)
        @Assert(c.displaySize, 21)
    }

    /** `DefaultCodec` 往返：六个字段（含三个 Int64）保真。 */
    @TestCase
    public func codecRoundTrip(): Unit {
        let c = ColumnInfoImpl('amount', 'Decimal', 12, 3, true, 14)
        let back = roundTrip(c)
        @Assert(back.name, 'amount')
        @Assert(back.typeName, 'Decimal')
        @Assert(back.length, 12)
        @Assert(back.scale, 3)
        @Assert(back.nullable, true)
        @Assert(back.displaySize, 14)
    }

    /** 严格解码（去掉 SILENCE）也可解出 —— 钉住"数据字段可解码"（设计 §3.4 规则 3）。 */
    @TestCase
    public func strictDecodeSucceeds(): Unit {
        let c = ColumnInfoImpl('amount', 'Decimal', 12, 3, true, 14)
        let back = decodeStrict<ColumnInfoImpl>(c.toData())
        @Assert(back.isSome())
        let x = back.getOrThrow()
        @Assert(x.name, 'amount')
        @Assert(x.length, 12)
        @Assert(x.nullable, true)
    }
}

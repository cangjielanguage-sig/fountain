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

import std.collection.{ArrayList, HashMap, Map}
import std.env.getVariable
import std.io.ByteBuffer
import std.runtime.{gc, getAllocatedHeapSize, getGCCount, getGCFreedSize}
import std.sync.AtomicInt64
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_codec.default.DefaultCodec
import fountain::f_dbd.common.SqlPayload
import fountain::f_data.base.*

/** 旧写法：与 `sqlPayloadOf` 同结构，仅参数包装不同。 */
private func legacySqlPayloadOf(sql: String, parameters: Map<Int64, Data>): SqlPayload {
    let payload = SqlPayload(sql)
    var max: Int64 = -1
    for ((index, _) in parameters) {
        if (index > max) {
            max = index
        }
    }
    var i: Int64 = 0
    while (i <= max) {
        match (parameters.get(i)) {
            case Some(data) => payload.add<DataAny>(DataAny(data))
            case None => payload.addNull()
        }
        i += 1
    }
    payload
}

private func encoded(payload: SqlPayload): Array<Byte> {
    let buf = ByteBuffer()
    DefaultCodec().encode<SqlPayload>(payload).finish().copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
    buf.bytes()
}

private func expectBytes(expected: Array<Byte>, actual: Array<Byte>): Unit {
    @Assert(expected.size, actual.size)
    for (i in 0..min(expected.size, actual.size)) {
        @Assert(expected[i], actual[i])
    }
}

private func dbdBenchEnabled(): Bool {
    match (getVariable("F_DBD_BENCH")) {
        case Some(v) => v == "1"
        case None => false
    }
}

private func dbdSettle(): Unit {
    for (_ in 0..3) {
        gc()
    }
}

private func dbdMeasure(action: () -> Unit): (Int64, Int64) {
    let allocs = ArrayList<Int64>()
    var attempts = 0
    while (allocs.size < 5 && attempts < 20) {
        attempts++
        dbdSettle()
        let heap0 = getAllocatedHeapSize()
        let freed0 = getGCFreedSize()
        action()
        let alloc = (getAllocatedHeapSize() - heap0) + (getGCFreedSize() - freed0)
        if (alloc >= 0) {
            allocs.add(alloc)
        }
    }
    if (allocs.size == 0) {
        return (-1, 0)
    }
    var best = allocs[0]
    for (a in allocs) {
        if (a < best) {
            best = a
        }
    }
    (best, allocs.size)
}

@Test
public class PayloadWrapping_test {
    private static let SQL: String = "update t set a=?,b=?,c=?,d=?,e=?,f=?,g=?,h=?"

    /** 8 个参数：生产路径与旧写法编码后逐字节相同。 */
    @TestCase
    public func payloadBytesMatchLegacy(): Unit {
        let params = HashMap<Int64, Data>()
        for (i in 0..8) {
            params[Int64(i)] = DataString("value-${i}")
        }
        let produced = sqlPayloadOf(SQL, params)
        let legacy = legacySqlPayloadOf(SQL, params)
        expectBytes(encoded(legacy), encoded(produced))
    }

    /** 空洞参数：缺位补 `DataNone`，与旧写法一致。 */
    @TestCase
    public func nullHoleMatchesLegacy(): Unit {
        let params = HashMap<Int64, Data>()
        for (i in 0..8) {
            if (i != 3) {
                params[Int64(i)] = DataString("value-${i}")
            }
        }
        let produced = sqlPayloadOf(SQL, params)
        let legacy = legacySqlPayloadOf(SQL, params)
        expectBytes(encoded(legacy), encoded(produced))
    }

    /** 往返：解码后再编码，结果仍与旧写法一致。 */
    @TestCase
    public func payloadRoundTripStable(): Unit {
        let params = HashMap<Int64, Data>()
        for (i in 0..8) {
            params[Int64(i)] = DataString("value-${i}")
        }
        let bytes = encoded(sqlPayloadOf(SQL, params))
        let decoded = DefaultCodec().decode<SqlPayload>(ByteBuffer(bytes)).getOrThrow()
        expectBytes(encoded(legacySqlPayloadOf(SQL, params)), encoded(decoded))
    }

    /**
     * 8 参数 payload 分配基准：打印生产路径与旧写法的 allocPerCall。
     *
     * 不作硬断言：GC 时机不可控，同一实现不同运行间可差数倍；稳定数据见设计文档的隔离探针。
     */
    @TestCase
    public func testBenchPayloadAllocation(): Unit {
        if (!dbdBenchEnabled()) {
            println("SKIP: 未设置 F_DBD_BENCH=1，payload 分配基准不执行")
            return
        }
        let ops: Int64 = 2000
        let params = HashMap<Int64, Data>()
        for (i in 0..8) {
            params[Int64(i)] = DataString("value-${i}")
        }
        let acc = AtomicInt64(0)

        let (producedAlloc, producedSamples) = dbdMeasure({ =>
            for (_ in 0..ops) {
                let payload = sqlPayloadOf(SQL, params)
                payload.addNull()
                acc.fetchAdd(1)
            }
        })
        let (legacyAlloc, legacySamples) = dbdMeasure({ =>
            for (_ in 0..ops) {
                let payload = legacySqlPayloadOf(SQL, params)
                payload.addNull()
                acc.fetchAdd(1)
            }
        })

        let producedPerCall = producedAlloc / ops
        println('DBD_PAYLOAD_BENCH case=produced allocTotal=${producedAlloc} allocPerCall=${producedPerCall} ' +
            'samples=${producedSamples}')
        println('DBD_PAYLOAD_BENCH case=legacy allocTotal=${legacyAlloc} ' +
            'allocPerCall=${legacyAlloc / ops} samples=${legacySamples}')
        @Assert(producedSamples > 0 && legacySamples > 0)
        // 分配量只记录：GC 时机不可控，同一实现在不同运行间可差 3 倍（1,696 / 595 B/次）。
        // 稳定对照见 design.md 的隔离探针（2,321 → 1,744 B/次）。
    }
}

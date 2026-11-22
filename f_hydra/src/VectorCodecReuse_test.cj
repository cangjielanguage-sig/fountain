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
package fountain::f_hydra

import std.env.getVariable
import std.runtime.{gc, getAllocatedHeapSize, getGCFreedSize}
import std.unittest.*
import std.unittest.testmacro.*

/**
 * `decodeDenseInto`：把解码结果写进调用方缓冲，供查询循环复用。
 *
 * 只覆盖新入口的契约与等价性；检索路径由 `FStoreVectorStore_test` 回归。
 */
@Test
public class VectorCodecReuse_test {

    @TestCase
    func intoMatchesDecode(): Unit {
        let src = [1.5f64, -2.25f64, 0.0f64, 3.75f64]
        let bytes = VectorCodec.encodeDense(src)
        let out = Array<Float64>(4, repeat: 0.0f64)
        let n = VectorCodec.decodeDenseInto(bytes, out)
        @Expect(n, 4)
        let legacy = VectorCodec.decodeDense(bytes)
        for (i in 0..4) {
            @Expect(out[i], legacy[i])
        }
    }

    @TestCase
    func shortBytesReturnsMinusOne(): Unit {
        let out = Array<Float64>(4, repeat: 0.0f64)
        @Expect(VectorCodec.decodeDenseInto(Array<Byte>(3, repeat: 0), out), -1)
    }

    @TestCase
    func zeroCountReturnsMinusOne(): Unit {
        let out = Array<Float64>(4, repeat: 0.0f64)
        @Expect(VectorCodec.decodeDenseInto(Array<Byte>(4, repeat: 0), out), -1)
    }

    @TestCase
    func declaredLengthBeyondReturnsMinusOne(): Unit {
        let bytes = VectorCodec.encodeDense([1.0f64, 2.0f64, 3.0f64])
        let truncated = bytes[0..bytes.size - 1]
        let out = Array<Float64>(3, repeat: 0.0f64)
        @Expect(VectorCodec.decodeDenseInto(truncated, out), -1)
    }

    @TestCase
    func outTooSmallReturnsMinusOne(): Unit {
        let bytes = VectorCodec.encodeDense([1.0f64, 2.0f64, 3.0f64])
        let out = Array<Float64>(2, repeat: 0.0f64)
        @Expect(VectorCodec.decodeDenseInto(bytes, out), -1)
    }

    @TestCase
    func bufferReuseAcrossLengths(): Unit {
        let buf = Array<Float64>(8, repeat: 0.0f64)
        let three = VectorCodec.encodeDense([1.0f64, 2.0f64, 3.0f64])
        let six = VectorCodec.encodeDense([1.0f64, 2.0f64, 3.0f64, 4.0f64, 5.0f64, 6.0f64])
        @Expect(VectorCodec.decodeDenseInto(three, buf), 3)
        @Expect(buf[0], 1.0f64)
        @Expect(buf[2], 3.0f64)
        @Expect(VectorCodec.decodeDenseInto(six, buf), 6)
        @Expect(buf[0], 1.0f64)
        @Expect(buf[5], 6.0f64)
        @Expect(VectorCodec.decodeDenseInto(three, buf), 3)
        @Expect(buf[2], 3.0f64)
    }

    /**
     * 768 维、2000 次解码：复用一块应比每次新建少至少一半的数组分配。
     *
     * 只度量 `decodeDense*` 本身；GC 噪声用「旧减新」的差值断言，不依赖绝对值。
     */
    @TestCase
    func benchReuseReducesAllocation(): Unit {
        if (!benchEnabled()) {
            println("HYDRA_DECODE_BENCH skipped (F_HYDRA_BENCH != 1)")
            return
        }
        let dim: Int64 = 768
        let rounds: Int64 = 2000
        let values = Array<Float64>(dim, repeat: 0.0f64)
        for (i in 0..dim) {
            values[i] = Float64(i) * 0.5f64
        }
        let bytes = VectorCodec.encodeDense(values)
        let sink = Array<Float64>(dim, repeat: 0.0f64)

        settle()
        let h0 = getAllocatedHeapSize()
        let f0 = getGCFreedSize()
        var legacyCount: Int64 = 0
        for (_ in 0..rounds) {
            legacyCount += VectorCodec.decodeDense(bytes).size
        }
        let legacyAlloc = (getAllocatedHeapSize() - h0) + (getGCFreedSize() - f0)

        settle()
        let h1 = getAllocatedHeapSize()
        let f1 = getGCFreedSize()
        var reuseCount: Int64 = 0
        for (_ in 0..rounds) {
            reuseCount += VectorCodec.decodeDenseInto(bytes, sink)
        }
        let reuseAlloc = (getAllocatedHeapSize() - h1) + (getGCFreedSize() - f1)

        @Expect(legacyCount, dim * rounds)
        @Expect(reuseCount, dim * rounds)
        println("HYDRA_DECODE_BENCH dim=${dim} rounds=${rounds} legacy=${legacyAlloc} reuse=${reuseAlloc}")
        // 每次 decodeDense 至少新建 dim × 8 B；留 2× 余量吸收 GC 噪声
        @Expect(legacyAlloc >= reuseAlloc + dim * 8 * rounds / 2)
    }

    private func benchEnabled(): Bool {
        match (getVariable("F_HYDRA_BENCH")) {
            case Some(v) => v == "1"
            case None => false
        }
    }

    private func settle(): Unit {
        for (_ in 0..3) {
            gc()
        }
    }
}

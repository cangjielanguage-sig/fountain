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

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
public class VectorCodecTest {

    /** 字节布局必须固定：小端 + count 头，跨语言/跨版本要能互读 */
    @TestCase
    func testDenseGoldenBytes(): Unit {
        let bytes = VectorCodec.encodeDense([1.0f64, -0.5f64])
        // count = 2
        @Expect(bytes[0], 0x02u8)
        @Expect(bytes[1], 0x00u8)
        @Expect(bytes[2], 0x00u8)
        @Expect(bytes[3], 0x00u8)
        // 1.0f32 = 0x3F800000（小端）
        @Expect(bytes[4], 0x00u8)
        @Expect(bytes[5], 0x00u8)
        @Expect(bytes[6], 0x80u8)
        @Expect(bytes[7], 0x3Fu8)
        // -0.5f32 = 0xBF000000
        @Expect(bytes[8], 0x00u8)
        @Expect(bytes[9], 0x00u8)
        @Expect(bytes[10], 0x00u8)
        @Expect(bytes[11], 0xBFu8)
    }

    @TestCase
    func testDenseRoundtripIsFloat32Accurate(): Unit {
        let source = [0.1f64, -0.25f64, 3.5f64]
        let decoded = VectorCodec.decodeDense(VectorCodec.encodeDense(source))
        @Expect(decoded.size, 3)
        @Expect(decoded[1], -0.25f64)
        @Expect(decoded[2], 3.5f64)
        // f32 截断：0.1 只会保留 ~7 位有效数字
        @Expect(decoded[0] - 0.1f64 < 0.000001f64 && 0.1f64 - decoded[0] < 0.000001f64, true)
    }

    @TestCase
    func testColbertRoundtripAndDimInference(): Unit {
        let source = [[1.0f64, 0.0f64, -1.0f64], [0.5f64, 0.5f64, 0.0f64]]
        let decoded = VectorCodec.decodeColbert(VectorCodec.encodeColbert(source))
        @Expect(decoded.size, 2)
        @Expect(decoded[0].size, 3)
        @Expect(decoded[1][0], 0.5f64)
    }

    @TestCase
    func testColbertPartsRespectByteLimit(): Unit {
        // 5 行 × 2 维 = 每行 8 字节，maxBytes=12 → 头部 4 + 1 行 8 = 12，每片 1 行
        let rows = ArrayList<Array<Float64>>()
        for(index in 0..5){
            rows.add([Float64(index), Float64(index) * 0.5f64])
        }
        let parts = VectorCodec.encodeColbertParts(rows.toArray(), maxBytes: 12)
        @Expect(parts.size, 5)
        for(part in parts){
            @Expect(part.size <= 12, true)
        }
        // 分片拼回来必须与整体一致
        let merged = ArrayList<Array<Float64>>()
        for(part in parts){
            for(row in VectorCodec.decodeColbert(part)){
                merged.add(row)
            }
        }
        @Expect(merged.size, 5)
        @Expect(merged[4][0], 4.0f64)
    }

    @TestCase
    func testEmptyVectors(): Unit {
        @Expect(VectorCodec.decodeDense(VectorCodec.encodeDense(Array<Float64>())).size, 0)
        @Expect(VectorCodec.decodeColbert(VectorCodec.encodeColbert(Array<Array<Float64>>())).size, 0)
        @Expect(VectorCodec.decodeDense(Array<Byte>()).size, 0)
        // 截断/损坏的输入不抛错
        @Expect(VectorCodec.decodeDense(Array<Byte>(10, repeat: 0xFF)).size, 0)
    }
}

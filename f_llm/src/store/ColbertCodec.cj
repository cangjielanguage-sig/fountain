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
package fountain::f_llm.store

import std.collection.*

/**
 * colbert 二进制编解码（§6.2）：
 * `count(Int32 LE) + count × dim × Float32 LE`。
 *
 * 不用 JSON 的原因：同体积约 3 倍，且每次读写都要多一轮解析。
 */
public class ColbertCodec {

    public static func encode(vectors: Array<Array<Float64>>): Array<Byte> {
        let count = vectors.size
        let dim = if(count == 0){ 0 } else { vectors[0].size }
        let bytes = Array<Byte>(4 + count * dim * 4, repeat: 0)
        writeInt32(bytes, 0, Int32(count))
        var offset = 4
        for(vector in vectors){
            for(value in vector){
                let bits = Float32(value).toBits()
                bytes[offset] = UInt8(bits & 0xFF)
                bytes[offset + 1] = UInt8((bits >> 8) & 0xFF)
                bytes[offset + 2] = UInt8((bits >> 16) & 0xFF)
                bytes[offset + 3] = UInt8((bits >> 24) & 0xFF)
                offset += 4
            }
        }
        bytes
    }

    public static func decode(bytes: Array<Byte>): Array<Array<Float64>> {
        if(bytes.size < 4){
            return []
        }
        let count = Int64(readInt32(bytes, 0))
        if(count <= 0 || bytes.size < 4 + count * 1024 * 4){
            // 维度不是 1024 也允许，按剩余字节推断
        }
        let dims: Int64 = if(count == 0){ 0 } else { (bytes.size - 4) / count / 4 }
        let vectors = ArrayList<Array<Float64>>()
        var offset = 4
        for(_ in 0..count){
            let vector = Array<Float64>(dims, repeat: 0.0f64)
            for(index in 0..dims){
                let bits = UInt32(bytes[offset]) |
                           (UInt32(bytes[offset + 1]) << 8) |
                           (UInt32(bytes[offset + 2]) << 16) |
                           (UInt32(bytes[offset + 3]) << 24)
                vector[index] = Float64(Float32.fromBits(bits))
                offset += 4
            }
            vectors.add(vector)
        }
        vectors.toArray()
    }

    private static func writeInt32(bytes: Array<Byte>, offset: Int64, value: Int32): Unit {
        let bits = UInt32(value)
        bytes[offset] = UInt8(bits & 0xFF)
        bytes[offset + 1] = UInt8((bits >> 8) & 0xFF)
        bytes[offset + 2] = UInt8((bits >> 16) & 0xFF)
        bytes[offset + 3] = UInt8((bits >> 24) & 0xFF)
    }

    private static func readInt32(bytes: Array<Byte>, offset: Int64): Int32 {
        let bits = UInt32(bytes[offset]) |
                   (UInt32(bytes[offset + 1]) << 8) |
                   (UInt32(bytes[offset + 2]) << 16) |
                   (UInt32(bytes[offset + 3]) << 24)
        Int32(bits)
    }
}

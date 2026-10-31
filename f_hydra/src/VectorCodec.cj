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

/**
 * 向量二进制编解码（与 `f_llm.store.ColbertCodec` **字节级兼容**）。
 *
 * 布局（全部小端）：
 * ```
 * dense   : count(Int32 LE) + count × Float32 LE                 // dim = count
 * colbert : count(Int32 LE) + count × dim × Float32 LE           // dim 由剩余字节推断
 * ```
 *
 * 之所以按这个布局：
 * 1. 与 PG/MySQL 的 `title_colbert`/`content_colbert` BYTEA 列一致，
 *    f_hydra 与数据库实现之间可以互相搬移同一份字节；
 * 2. 不写死 dim，换 768/1024 维模型不用改格式；
 * 3. f32 比文本小 2~3 倍，且不需要解析。
 *
 * 精度：写入即按 f32 截断（`Float32(value)`），读回是 `Float64(Float32)`，
 * 与数据库列存 f32 的行为一致；不要期望 bit-level 还原原始 Float64。
 */
public class VectorCodec {
    /** 单条 value 的软上限：f_store 的 SSTable 数据块阈值 4KB，设计文档建议 value ≤ 64KB */
    public static const DEFAULT_PART_BYTES: Int64 = 64 * 1024

    private init() {
    }

    public static func encodeDense(values: Array<Float64>): Array<Byte> {
        let bytes = Array<Byte>(4 + values.size * 4, repeat: 0)
        writeInt32(bytes, 0, Int32(values.size))
        var offset = 4
        for(value in values){
            writeFloat32(bytes, offset, value)
            offset += 4
        }
        bytes
    }

    public static func decodeDense(bytes: Array<Byte>): Array<Float64> {
        if(bytes.size < 4){
            return Array<Float64>()
        }
        let count = Int64(readUInt32(bytes, 0))
        if(count <= 0 || bytes.size < 4 + count * 4){
            return Array<Float64>()
        }
        let values = Array<Float64>(count, repeat: 0.0f64)
        var offset = 4
        for(index in 0..count){
            values[index] = readFloat32(bytes, offset)
            offset += 4
        }
        values
    }

    public static func encodeColbert(vectors: Array<Array<Float64>>): Array<Byte> {
        let count = vectors.size
        let dim = if(count == 0){ 0 } else { vectors[0].size }
        let bytes = Array<Byte>(4 + count * dim * 4, repeat: 0)
        writeInt32(bytes, 0, Int32(count))
        var offset = 4
        for(vector in vectors){
            for(value in vector){
                writeFloat32(bytes, offset, value)
                offset += 4
            }
        }
        bytes
    }

    public static func decodeColbert(bytes: Array<Byte>): Array<Array<Float64>> {
        let vectors = ArrayList<Array<Float64>>()
        if(bytes.size < 4){
            return vectors.toArray()
        }
        let count = Int64(readUInt32(bytes, 0))
        if(count <= 0){
            return vectors.toArray()
        }
        let dim = (Int64(bytes.size) - 4) / count / 4
        if(dim <= 0){
            return vectors.toArray()
        }
        var offset = 4
        for(_ in 0..count){
            let vector = Array<Float64>(dim, repeat: 0.0f64)
            for(index in 0..dim){
                vector[index] = readFloat32(bytes, offset)
                offset += 4
            }
            vectors.add(vector)
        }
        vectors.toArray()
    }

    /**
     * 把 colbert 切成多个 value（每个 ≤ `maxBytes`），避免单条 value 过大。
     *
     * 96 token × 1024 维 × 4B ≈ 384KB，是建议值（64KB）的 6 倍；
     * f_store 没有硬性上限，但大 value 会拖慢 compaction，所以分片存储。
     */
    public static func encodeColbertParts(vectors: Array<Array<Float64>>,
                                          maxBytes!: Int64 = DEFAULT_PART_BYTES): ArrayList<Array<Byte>> {
        let parts = ArrayList<Array<Byte>>()
        if(vectors.size == 0){
            parts.add(encodeColbert(Array<Array<Float64>>()))
            return parts
        }
        let dim = vectors[0].size
        let rowBytes = Int64(dim) * 4
        if(rowBytes <= 0){
            parts.add(encodeColbert(Array<Array<Float64>>()))
            return parts
        }
        // 预留 4 字节头部，至少一行
        let rowsPerPart = if((maxBytes - 4) / rowBytes < 1){ 1 } else { (maxBytes - 4) / rowBytes }
        var start: Int64 = 0
        while(start < Int64(vectors.size)){
            let end = minOf(Int64(vectors.size), start + rowsPerPart)
            let slice = ArrayList<Array<Float64>>()
            for(index in start..end){
                slice.add(vectors[index])
            }
            parts.add(encodeColbert(slice.toArray()))
            start = end
        }
        parts
    }

    private static func minOf(a: Int64, b: Int64): Int64 {
        if(a < b){ a }else{ b }
    }

    private static func writeInt32(bytes: Array<Byte>, offset: Int64, value: Int32): Unit {
        let bits = UInt32(value)
        bytes[offset] = UInt8(bits & 0xFF)
        bytes[offset + 1] = UInt8((bits >> 8) & 0xFF)
        bytes[offset + 2] = UInt8((bits >> 16) & 0xFF)
        bytes[offset + 3] = UInt8((bits >> 24) & 0xFF)
    }

    private static func readUInt32(bytes: Array<Byte>, offset: Int64): UInt32 {
        let bits = UInt32(bytes[offset]) |
                   (UInt32(bytes[offset + 1]) << 8) |
                   (UInt32(bytes[offset + 2]) << 16) |
                   (UInt32(bytes[offset + 3]) << 24)
        bits
    }

    private static func writeFloat32(bytes: Array<Byte>, offset: Int64, value: Float64): Unit {
        let bits = Float32(value).toBits()
        bytes[offset] = UInt8(bits & 0xFF)
        bytes[offset + 1] = UInt8((bits >> 8) & 0xFF)
        bytes[offset + 2] = UInt8((bits >> 16) & 0xFF)
        bytes[offset + 3] = UInt8((bits >> 24) & 0xFF)
    }

    private static func readFloat32(bytes: Array<Byte>, offset: Int64): Float64 {
        let bits = UInt32(bytes[offset]) |
                   (UInt32(bytes[offset + 1]) << 8) |
                   (UInt32(bytes[offset + 2]) << 16) |
                   (UInt32(bytes[offset + 3]) << 24)
        Float64(Float32.fromBits(bits))
    }
}

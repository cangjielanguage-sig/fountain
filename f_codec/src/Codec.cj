/*
Copyright (c) 2025 WuJingrun（吴京润）

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
package f_codec

/**
```md
| ------------------- | ------------ |
| None(n)             | 0\|0000      |
| 字符串(s)           | 1\|0001      |
| Bool(b)             | 2\|0010      |
| 整数(i)             | 3\|0011      |
| 浮点数(f)           | 4\|0100      |
| BigInt(bi1\|bi2)    | 5\|0101      |
| Decimal(r1)         | 6\|0110      |
| Decimal(r2)         | 7\|0111      |
| Duration(d1)        | 8\|1000      |
| Duration(d2)        | 9\|1001      |
| DateTime(t1)        | 10\|1010     |
| DateTime(t2)        | 11\|1011     |
| list\|array\|set(l) | 12\|1100     |
| map(m)              | 13\|1101     |
| object(o)           | 14\|1110     |
| inputstream(is)     | 15\|1111     |
```
*/
public interface Encoder {
    func encode<T>(data: T): Encoder where T <: DataFields<T> 
    func encodeNone(): Encoder
    func encode(value: Bool): Encoder
    func encode(value: String): Encoder
    func encode(value: Int8): Encoder
    func encode(value: UInt8): Encoder
    func encode(value: Int16): Encoder
    func encode(value: UInt16): Encoder
    func encode(value: Int32): Encoder
    func encode(value: UInt32): Encoder
    func encode(value: Int64): Encoder
    func encode(value: UInt64): Encoder
    func encode(value: Float16): Encoder
    func encode(value: Float32): Encoder
    func encode(value: Float64): Encoder
    func encode(value: BigInt): Encoder
    func encode(value: Decimal): Encoder
    func encode(value: Duration): Encoder
    func encode(value: DateTime): Encoder
    func encode(value: Array<Byte>): Encoder
    func encode(value: ArrayList<Byte>): Encoder {
        encode(value.unsafeData())
    }
    func encode(data: InputStream, size: Int64): Encoder
    func encode(data: File): Encoder
    func finish(): BytesCopyTo
}

public interface Decoder {
    func decode<T>(input: InputStream): ?T where T <: DataFields<T>
}

public interface Codec <: Encoder & Decoder {}

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
package f_codec.default

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
public class DefaultCodec <: Codec {
    private static let ZERO_DECIMAL = Decimal(0)
    private static let ZERO_BIGINT = BigInt(0)
    private static let MIN_INT = BigInt(Int64.Min)
    private static let MAX_INT = BigInt(UInt64.Max)
    private static let TEN_POW_NINE = BigInt(10 ** 9)
    private static let typeMurmurHashs = ConcurrentHashMap<String, BigInt>()
    private static let typeMurmurCreators = ConcurrentHashMap<BigInt, () -> SimpleDataObject>()
    private var size = 0
    private let inputs = ArrayList<InputStream>([ByteBuffer()])

    private func lastBuffer(): ByteBuffer {
        match (inputs[inputs.size - 1]) {
            case x: ByteBuffer => x
            case _ =>
                let buf = ByteBuffer()
                inputs.add(buf)
                buf
        }
    }
    private func encode(data: Data): Encoder {
        let buffer = lastBuffer()
        match (data) {
            case _: DataNone => encodeNone(buffer)
            case x: DataBool => encode(x.data, buffer)
            case x: DataString => encode(x.data, buffer)
            case x: DataReal => encode(x.data, buffer)
            case x: DataDuration => encode(x.data, buffer)
            case x: DataDateTime => encode(x.data, buffer)
            case x: DataCollection<ArrayList<Byte>, Byte> => encode(x.data)
            case x: DataCollection<Array<Byte>, Byte> => encode(x.data)
            case x: Collection<Data> =>
                if (x.isEmpty()) {
                    buffer.writeByte(COLLECTION.value)
                    return this
                }
                let sizeBuf = encodeSizeOfValue(COLLECTION, x.size)
                inputs.add(ByteBuffer(sizeBuf))
                for (item in x) {
                    encode(item)
                }
                this
            case x: Collection<(Data, Data)> =>
                if (x.isEmpty()) {
                    buffer.writeByte(MAP.value)
                    return this
                }
                let sizeBuf = encodeSizeOfValue(MAP, x.size)
                inputs.add(ByteBuffer(sizeBuf))
                for ((k, v) in x) {
                    encode(k)
                    encode(v)
                }
                this
            case x: DataInputStream => match (x.data) {
                case f: File => encode(f)
                case x => throw CodecException(
                    'current InputStream cannot be serialized due to without size, which type is ${TypeInfo.of(x)}')
            }
            case x: SimpleDataObject => 
                let typeName = x.typeInfo.qualifiedName
                let typeMurmur = typeMurmurHashs.computeIfAbsent(typeName){murmurHash128X64(typeName).value}
                let typeMurmurCreator = typeMurmurCreators.computeIfAbsent(typeMurmur){{=>x.newData()}}
                encodeBigInt2(OBJECT, typeMurmur, buffer)
                let sizeBuf = encodeSizeOfEncoded(x.size)
                inputs.add(ByteBuffer(sizeBuf))
                for (f in x.fields()) {
                    encode(f.name)
                    encode(f.get(x.getData()))
                }
                this
            case x: Collection<(String, Data)> =>
                if (x.isEmpty()) {
                    buffer.writeByte(MAP.value)
                    return this
                }
                let sizeBuf = encodeSizeOfValue(MAP, x.size)
                inputs.add(ByteBuffer(sizeBuf))
                for ((n, d) in x) {
                    encode(n.toData())
                    encode(d)
                }
                this
            case x => try {
                throw CodecException("Unsupported type: ${TypeInfo.of(x)}")
            } catch (e: Exception) {
                throw CodecException('Unsupported type', e)
            }
        }
    }
    public func encode<T>(data: T): Encoder where T <: DataFields<T> {
        encode(data.toData())
        this
    }
    private func encodeNone(buffer: ByteBuffer): Encoder {
        buffer.writeByte(DataType.NONE.value)
        size++
        this
    }
    public func encodeNone(): Encoder {
        encodeNone(lastBuffer())
    }
    private func encode(value: Bool, buffer: ByteBuffer): Encoder {
        buffer.writeByte(if (value) {
            DataType.BOOL.value | 1
        } else {
            DataType.BOOL.value
        })
        size++
        this
    }
    public func encode(value: Bool): Encoder {
        encode(value, lastBuffer())
    }
    private func encode(value: String, buffer: ByteBuffer): Encoder {
        let ss = value.size
        if (ss == 0) {
            buffer.writeByte(DataType.STRING.value)
            size++
        } else {
            let buf = encodeSizeOfValue(STRING, ss)
            buffer.write(buf)
            size += buf.size
            buffer.write(value.unsafeBytes())
            size += ss
        }
        this
    }
    public func encode(value: String): Encoder {
        encode(value, lastBuffer())
    }
    private func encode(value: Int8, buffer: ByteBuffer): Encoder {
        buffer.write([DataType.INT.value | 1 | if (value < 0) {
            1 << 3
        } else {
            0
        }, UInt8(if (value < 0) {
            !value
        } else {
            value
        })])
        size += 2
        this
    }
    public func encode(value: Int8): Encoder {
        encode(value, lastBuffer())
    }
    private func encode(value: UInt8, buffer: ByteBuffer): Encoder {
        buffer.write([DataType.INT.value | 1, value])
        size += 2
        this
    }
    public func encode(value: UInt8): Encoder {
        encode(value, lastBuffer())
    }
    private func encode(dataType: DataType, sign: Bool, value: UInt16, buffer: ByteBuffer): Encoder {
        let size = if (value <= 0xff) {
            1
        } else {
            2
        }
        buffer.write(Array<Byte>(1 + size) {
            i => if (i == 0) {
                dataType.value | UInt8(size) | if (sign) {
                    0
                } else {
                    1 << 3
                }
            } else {
                UInt8((value >> (8 * (2 - i))) & 0xff)
            }
        })
        this.size += 1 + size
        this
    }
    private func encode(value: Int16, buffer: ByteBuffer): Encoder {
        let sign = value >= 0
        encode(DataType.INT, sign, if (sign) {
            UInt16(value)
        } else {
            UInt16(!value)
        }, buffer)
    }
    public func encode(value: Int16): Encoder {
        encode(value, lastBuffer())
    }
    private func encode(value: UInt16, buffer: ByteBuffer): Encoder {
        encode(DataType.INT, true, value, buffer)
    }
    public func encode(value: UInt16): Encoder {
        encode(value, lastBuffer())
    }
    private func encode(dataType: DataType, sign: Bool, value: UInt32, buffer: ByteBuffer): Encoder {
        let size: Int64 = if (value <= 0xff) {
            1
        } else if (value <= 0xffff) {
            2
        } else if (value <= 0xffffff) {
            3
        } else {
            4
        }
        buffer.write(Array<Byte>(1 + size) {
            i => if (i == 0) {
                dataType.value | UInt8(size) | if (sign) {
                    0
                } else {
                    1 << 3
                }
            } else {
                UInt8((value >> (8 * (4 - i))) & 0xff)
            }
        })
        this.size += 1 + size
        this
    }
    private func encode(value: Int32, buffer: ByteBuffer): Encoder {
        let sign = value >= 0
        encode(DataType.INT, sign, if (sign) {
            UInt32(value)
        } else {
            UInt32(!value)
        }, buffer)
    }
    public func encode(value: Int32): Encoder {
        encode(value, lastBuffer())
    }
    private func encode(value: UInt32, buffer: ByteBuffer): Encoder {
        encode(DataType.INT, true, value, buffer)
    }
    public func encode(value: UInt32): Encoder {
        encode(value, lastBuffer())
    }
    private func encode(dataType: DataType, sign: Bool, value: UInt64, buffer: ByteBuffer): Encoder {
        let size: Int64 = if (value <= 0xffu64) {
            1
        } else if (value <= 0xffffu64) {
            2
        } else if (value <= 0xffffffu64) {
            3
        } else if (value <= 0xffffffffu64) {
            4
        } else if (value <= 0xffffffffffu64) {
            5
        } else if (value <= 0xffffffffffffu64) {
            6
        } else if (value <= 0xffffffffffffffu64) {
            7
        } else {
            0
        }
        buffer.write(Array<Byte>(1 + size) {
            i => if (i == 0) {
                dataType.value | UInt8(size) | if (sign) {
                    0
                } else {
                    1 << 3
                }
            } else {
                UInt8((value >> (8 * (4 - i))) & 0xff)
            }
        })
        this.size += 1 + size
        this
    }
    private func encode(value: Int64, buffer: ByteBuffer): Encoder {
        let sign = value >= 0
        encode(DataType.INT, sign, if (sign) {
            UInt64(value)
        } else {
            UInt64(!value)
        }, buffer)
    }
    public func encode(value: Int64): Encoder {
        encode(value, lastBuffer())
    }
    private func encode(value: UInt64, buffer: ByteBuffer): Encoder {
        encode(DataType.INT, true, value, buffer)
    }
    public func encode(value: UInt64): Encoder {
        encode(value, lastBuffer())
    }
    private func encode(value: Float16, buffer: ByteBuffer): Encoder {
        if (value.isNaN()) {
            buffer.write(DataType.FLOAT.value)
            this
        } else if (value == Float16.Inf) {
            buffer.write(DataType.FLOAT.value | 0x07)
            this
        } else if (value == -Float16.Inf) {
            buffer.write(DataType.FLOAT.value | 0x0f)
            this
        } else {
            encode(DataType.FLOAT, value >= 0.0, value.toBits(), buffer)
        }
    }
    public func encode(value: Float16): Encoder {
        encode(value, lastBuffer())
    }
    private func encode(value: Float32, buffer: ByteBuffer): Encoder {
        if (value.isNaN()) {
            buffer.write(DataType.FLOAT.value)
            this
        } else if (value == Float32.Inf) {
            buffer.write(DataType.FLOAT.value | 0x07)
            this
        } else if (value == -Float32.Inf) {
            buffer.write(DataType.FLOAT.value | 0x0f)
            this
        } else {
            encode(DataType.FLOAT, value >= 0.0, value.toBits(), buffer)
        }
    }
    public func encode(value: Float32): Encoder {
        encode(value, lastBuffer())
    }
    private func encode(value: Float64, buffer: ByteBuffer): Encoder {
        if (value.isNaN()) {
            buffer.write(DataType.FLOAT.value)
            this
        } else if (value == Float64.Inf) {
            buffer.write(DataType.FLOAT.value | 0x07)
            this
        } else if (value == -Float64.Inf) {
            buffer.write(DataType.FLOAT.value | 0x0f)
            this
        } else {
            encode(DataType.FLOAT, value >= 0.0, value.toBits(), buffer)
        }
    }
    public func encode(value: Float64): Encoder {
        encode(value, lastBuffer())
    }
    private func encodeBigInt2(dataType: DataType, value: BigInt, buffer: ByteBuffer): Encoder {
        let sign = value >= ZERO_BIGINT
        let bytes = if (sign) {
            value.toBytes()[1..]
        } else {
            value.toBytes()
        }
        let sizeBytes = encodeSizeOfValue(dataType, sign, bytes.size, forInt: true)
        buffer.write(sizeBytes)
        buffer.write(bytes)
        size += sizeBytes.size + bytes.size
        this
    }
    private func encode(dataType: DataType, value: BigInt, buffer: ByteBuffer): Encoder {
        if (value >= MIN_INT && value < ZERO_BIGINT) {
            encode(dataType, false, UInt64(!value.toInt64()), buffer)
        } else if (value >= ZERO_BIGINT && value <= MAX_INT) {
            encode(dataType, true, value.toUInt64(), buffer)
        } else {
            encodeBigInt2(dataType, value, buffer)
        }
        this
    }
    private func encode(value: BigInt, buffer: ByteBuffer): Encoder {
        encode(DataType.BIGINT, value, buffer)
    }
    public func encode(value: BigInt): Encoder {
        encode(value, lastBuffer())
    }
    private func encode(value: Decimal, buffer: ByteBuffer): Encoder {
        let sign = value >= ZERO_DECIMAL
        let scale = value.scale
        let valval = value.value
        if (scale == 0) {
            encode(valval, buffer)
        } else {
            let bytes = if (sign) {
                valval.toBytes()[1..]
            } else {
                valval.toBytes()
            }
            let sizeBytes = encodeSizeOfValue(if (valval >= MIN_INT && valval <= MAX_INT) {
                DataType.DECIMAL1
            } else {
                DataType.DECIMAL2
            }, sign, bytes.size, forInt: true)
            buffer.write(sizeBytes)
            buffer.write(bytes)
            let scaleBytes = encodeSizeOfEncoded(Int64(scale))
            buffer.write(scaleBytes)
            size += sizeBytes.size + bytes.size + scaleBytes.size
        }
        this
    }
    public func encode(value: Decimal): Encoder {
        encode(value, lastBuffer())
    }
    private func encode(value: Duration, buffer: ByteBuffer): Encoder {
        let int = BigInt(value.toSeconds()) * TEN_POW_NINE + BigInt(
            (value - Duration.second * value.toSeconds()).toNanoseconds())
        if (int >= MIN_INT && int < ZERO_BIGINT) {
            encode(DataType.DURATION1, false, UInt64(!(int.toInt64())), buffer)
        } else if (int >= ZERO_BIGINT && int <= MAX_INT) {
            encode(DataType.DURATION1, true, int.toUInt64(), buffer)
        } else {
            let sign = int >= ZERO_BIGINT
            let bytes = if (sign) {
                int.toBytes()[1..]
            } else {
                int.toBytes()
            }
            let sizeBytes = encodeSizeOfValue(DataType.DURATION2, sign, bytes.size, forInt: true)
            buffer.write(sizeBytes)
            buffer.write(bytes)
            size += sizeBytes.size + bytes.size
        }
        this
    }
    public func encode(value: Duration): Encoder {
        encode(value, lastBuffer())
    }
    private func encode(value: DateTime, buffer: ByteBuffer): Encoder {
        let duration = value - DateTime.UnixEpoch
        let int = BigInt(duration.toSeconds()) * TEN_POW_NINE + BigInt(
            (duration - Duration.second * duration.toSeconds()).toNanoseconds())
        if (int >= MIN_INT && int < ZERO_BIGINT) {
            encode(DataType.DATETIME1, false, UInt64(!(int.toInt64())), buffer)
        } else if (int >= ZERO_BIGINT && int <= MAX_INT) {
            encode(DataType.DATETIME1, true, int.toUInt64(), buffer)
        } else {
            let sign = int >= ZERO_BIGINT
            let bytes = if (sign) {
                int.toBytes()[1..]
            } else {
                int.toBytes()
            }
            let sizeBytes = encodeSizeOfValue(DataType.DATETIME2, sign, bytes.size, forInt: true)
            buffer.write(sizeBytes)
            buffer.write(bytes)
            size += sizeBytes.size + bytes.size
        }
        this
    }
    public func encode(value: DateTime): Encoder {
        encode(value, lastBuffer())
    }
    public func encode<T>(value: Collection<T>): Encoder where T <: DataFields<T> {
        if (value.isEmpty()) {
            lastBuffer().writeByte(COLLECTION.value)
            return this
        }
        let sizeBuf = encodeSizeOfValue(COLLECTION, value.size)
        for (item in value) {
            encode<T>(item)
        }
        this
    }
    public func encode<K, V>(value: Map<K, V>): Encoder where K <: Equatable<K> & DataFields<K>, V <: DataFields<V> {
        if (value.isEmpty()) {
            lastBuffer().writeByte(MAP.value)
            return this
        }
        let sizeBuf = encodeSizeOfValue(MAP, value.size)
        for ((k, v) in value) {
            encode<K>(k)
            encode<V>(v)
        }
        this
    }
    public func encode(value: Array<Byte>): Encoder {
        encode(ByteBuffer(value), value.size)
    }
    public func encode(data: InputStream, size: Int64): Encoder {
        let sizeBuf = encodeSizeOfValue(INPUTSTREAM, false, size, forInt: true)
        inputs.add(ByteBuffer(sizeBuf))
        inputs.add(data)
        this.size += size + sizeBuf.size //+sizeBuf.size是类型头的1字节 + size序列化后的字节数
        this
    }
    public func encode(data: File): Encoder {
        var sizeBuf = encodeSizeOfValue(INPUTSTREAM, true, size, forInt: true)
        inputs.add(ByteBuffer(sizeBuf))
        inputs.add(data)
        this.size += size + sizeBuf.size
        let fileName = data.info.path.fileName.unsafeBytes()
        sizeBuf = encodeSizeOfEncoded(fileName.size)
        inputs.add(ByteBuffer(sizeBuf))
        inputs.add(ByteBuffer(fileName))
        this.size += sizeBuf.size + fileName.size
        this
    }
    private func encodeSizeOfValue(dataType: DataType, sign: Bool, value: Int64, forInt!: Bool): Array<Byte> {
        let s = if (value <= 0xff) {
            1
        } else if (value <= 0xffff) {
            2
        } else if (value <= 0xffffff) {
            3
        } else if (value <= 0xffffffff) {
            4
        } else if (value <= 0xffffffffff) {
            5
        } else if (value <= 0xffffffffffff) {
            6
        } else if (value <= 0xffffffffffffff) {
            7
        } else if (forInt) {
            0
        } else {
            8
        }
        let bytes = Array<Byte>(s + 1) {
            i => if (i == 0) {
                dataType.value | UInt8(s) | if (!forInt || sign) {
                    0
                } else {
                    1 << 3
                }
            } else {
                UInt8((value >> (8 * (s - i))) & 0xff)
            }
        }
        bytes
    }
    private func encodeSizeOfValue(dataType: DataType, value: Int64): Array<Byte> {
        encodeSizeOfValue(dataType, true, value, forInt: false)
    }
    private func encodeSizeOfEncoded(size: Int64): Array<Byte> {
        let bytes = if (size <= 0xf) {
            [UInt8(size)]
        } else if (size <= 0xfff) {
            [1u8 << 4u8 | UInt8(size >> 8), UInt8(size & 0xff)]
        } else if (size <= 0xfffff) {
            [2u8 << 4u8 | UInt8(size >> 16), UInt8(size >> 8 & 0xff), UInt8(size & 0xff)]
        } else if (size <= 0xfffffff) {
            [3u8 << 4u8 | UInt8(size >> 24), UInt8(size >> 16 & 0xff), UInt8(size >> 8 & 0xff), UInt8(size & 0xff)]
        } else if (size <= 0xfffffffff) {
            [4u8 << 4u8 | UInt8(size >> 32), UInt8(size >> 24 & 0xff), UInt8(size >> 16 & 0xff), UInt8(size >> 8 & 0xff),
                UInt8(size & 0xff)]
        } else if (size <= 0xfffffffffff) {
            [5u8 << 4u8 | UInt8(size >> 40), UInt8(size >> 32 & 0xff), UInt8(size >> 24 & 0xff), UInt8(size >> 16 & 0xff),
                UInt8(size >> 8 & 0xff), UInt8(size & 0xff)]
        } else if (size <= 0xfffffffffffff) {
            [6u8 << 4u8 | UInt8(size >> 48), UInt8(size >> 40 & 0xff), UInt8(size >> 32 & 0xff), UInt8(size >> 24 & 0xff),
                UInt8(size >> 16 & 0xff), UInt8(size >> 8 & 0xff), UInt8(size & 0xff)]
        } else if (size <= 0xfffffffffffffff) {
            [7u8 << 4u8 | UInt8(size >> 56), UInt8(size >> 48 & 0xff), UInt8(size >> 40 & 0xff), UInt8(size >> 32 & 0xff),
                UInt8(size >> 24 & 0xff), UInt8(size >> 16 & 0xff), UInt8(size >> 8 & 0xff), UInt8(size & 0xff)]
        } else {
            [8u8 << 4u8, UInt8(size >> 56 & 0xff), UInt8(size >> 48 & 0xff), UInt8(size >> 40 & 0xff),
                UInt8(size >> 32 & 0xff), UInt8(size >> 24 & 0xff), UInt8(size >> 16 & 0xff), UInt8(size >> 8 & 0xff),
                UInt8(size & 0xff)]
        }
        bytes
    }
    private func decodeSizeOfEncoded(input: InputStream): Int64 {
        var bytes = [0u8]
        var size = input.read(bytes)
        if(size == 0){
            throw CodecException('size of bytes to decode must not be zero')
        }
        let head = bytes[0]
        bytes = Array<Byte>(Int64(head >> 4), repeat: 0)
        size = input.read(bytes)
        if(size < bytes.size){
            throw CodecException('size of bytes to decode is less than encoded in head, head: ${toHex(head)}, actual: ${bytes.size}')
        }
        if(size == 0){
            Int64(head & 0x0f)
        } else if (size == 1) {
            Int64(head & 0x0f) << 8 | Int64(bytes[0])
        } else if (size == 2) {
            Int64(head & 0x0f) << 16 | Int64(bytes[0]) << 8 | Int64(bytes[1])
        } else if (size == 3) {
            Int64(head & 0x0f) << 24 | Int64(bytes[0]) << 16 | Int64(bytes[1]) << 8 | Int64(bytes[2])
        } else if (size == 4) {
            Int64(head & 0x0f) << 32 | Int64(bytes[0]) << 24 | Int64(bytes[1]) << 16 | Int64(bytes[2]) << 8 | Int64(bytes[3])
        } else if (size == 5) {
            Int64(head & 0x0f) << 40 | Int64(bytes[0]) << 32 | Int64(bytes[1]) << 24 | Int64(bytes[2]) << 16 | Int64(bytes[3]) << 8 | Int64(bytes[4])
        } else if (size == 6) {
            Int64(head & 0x0f) << 48 | Int64(bytes[0]) << 40 | Int64(bytes[1]) << 32 | Int64(bytes[2]) << 24 | Int64(bytes[3]) << 16 | Int64(bytes[4]) << 8 | Int64(bytes[5])
        } else if (size == 7) {
            Int64(head & 0x0f) << 56 | Int64(bytes[0]) << 48 | Int64(bytes[1]) << 40 | Int64(bytes[2]) << 32 | Int64(bytes[3]) << 24 | Int64(bytes[4]) << 16 | Int64(bytes[5]) << 8 | Int64(bytes[6])
        } else {
            Int64(bytes[0]) << 56 | Int64(bytes[1]) << 48 | Int64(bytes[2]) << 40 | Int64(bytes[3]) << 32 | Int64(bytes[4]) << 24 | Int64(bytes[5]) << 16 | Int64(bytes[6]) << 8 | Int64(bytes[7])
        }
    }
    public func finish(): InputStream {
        // ChainedInputStream<InputStream>(
        //     [ByteBuffer(encodeSizeOfEncoded(size)), ChainedInputStream<InputStream>(inputs.unsafeData())])
        ChainedInputStream<InputStream>(inputs.unsafeData())
    }
    private static let hex = '0123456789abcdef'.toRuneArray()
    private func toHex(b: Byte): String {
        '${hex[Int64(b >> 4)]}${hex[Int64(b & 0x0f)]}'
    }
    private func parseInt64(head: Byte, sign: Bool, bytes: Array<Byte>): Int64 {
        let s = bytes.size
        var v = if (s == 1) {
            Int64(bytes[0])
        } else if (s == 2) {
            Int64(bytes[0]) << 8 | Int64(bytes[1])
        } else if (s == 3) {
            Int64(bytes[0]) << 16 | Int64(bytes[1]) << 8 | Int64(bytes[2])
        } else if (s == 4) {
            Int64(bytes[0]) << 24 | Int64(bytes[1]) << 16 | Int64(bytes[2]) << 8 | Int64(bytes[3])
        } else if (s == 5) {
            Int64(bytes[0]) << 32 | Int64(bytes[1]) << 24 | Int64(bytes[2]) << 16 | Int64(bytes[3]) << 8 | Int64(bytes[4])
        } else if (s == 6) {
            Int64(bytes[0]) << 40 | Int64(bytes[1]) << 32 | Int64(bytes[2]) << 24 | Int64(bytes[3]) << 16 | Int64(bytes[4]) << 8 | Int64(bytes[5])
        } else if (s == 7) {
            Int64(bytes[0]) << 48 | Int64(bytes[1]) << 40 | Int64(bytes[2]) << 32 | Int64(bytes[3]) << 24 | Int64(bytes[4]) << 16 | Int64(bytes[5]) << 8 | Int64(bytes[6])
        } else {
            Int64(bytes[0]) << 56 | Int64(bytes[1]) << 48 | Int64(bytes[2]) << 40 | Int64(bytes[3]) << 32 | Int64(bytes[4]) << 24 | Int64(bytes[5]) << 16 | Int64(bytes[6]) << 8 | Int64(bytes[7])
        }
        v = if(sign){
            v
        } else {
            !v
        }
        if((sign && v < 0) || (!sign && v > 0)){
            throw CodecException('current data head is ${toHex(head)}, but sign mark is opposite to actual value, value: ${v}, bytes: ${bytes}.')
        }
        v
    }
    private func decodeData(input: InputStream, fileThreshold: Int64): Data {
        // decodeSizeOfEncoded(input)
        var bytes = [0u8]
        var size = input.read(bytes)
        if(size == 0 || bytes[0] == 0){
            return DataNone.INSTANCE
        } else if (bytes[0] <= 0x0f) {
            throw CodecException('Illegal serialization header ${toHex(bytes[0])}')
        }
        let head = bytes[0] 
        let dataType = head & 0xf0
        if (dataType == DataType.STRING.value) {
            let ss = Int64(head & 0x0f)
            if(ss == 0){
                return ''.toData()
            }
            bytes = Array<Byte>(ss, repeat: 0)
            size = input.read(bytes)
            if(size < ss){
                throw CodecException('current data head is ${toHex(head)} but read ${size} bytes')
            }
            String.fromUtf8(bytes).toData()
        } else if (dataType == DataType.BOOL.value) {
            let value = head & 0xff
            if(value == 0x01) {
                DataBool.TRUE
            }else if(value == 0x00){
                DataBool.FALSE
            }else{
                throw CodecException('current data head is ${toHex(head)}, it is type of BOOL but illegal value')
            }
        } else if (dataType == DataType.INT.value) {
            var s = Int64(head & 0x07)
            if (s == 0){
                s = 8
            }
            bytes = Array<Byte>(s, repeat: 0)
            size = input.read(bytes)
            if(size < s){
                throw CodecException('current data head is ${toHex(head)}, but read ${size} bytes')
            }
            let sign = (head & 0x08) == 0 
            Decimal(BigInt(sign, bytes)).toData()
        } else if (dataType == DataType.FLOAT.value) {
            if (head == DataType.FLOAT.value){
                return Float64.NaN.toData()
            } else if ((head & 0x0f) == 0x0f) {
                return (-Float64.Inf).toData()
            } else if ((head & 0x0f) == 0x07) {
                return Float64.Inf.toData()
            } else {
                throw CodecException('current data head is ${toHex(head)}')
            }
            var s = Int64(head & 0x07)
            if (s == 0){
                s = 8
            }
            if (s != 2 && s != 4 && s != 8) {
                throw CodecException('current data head is ${toHex(head)}, only 2 or 4 or 8 for size of FLOAT.')
            }
            bytes = Array<Byte>(s, repeat: 0)
            size = input.read(bytes)
            if(size < s){
                throw CodecException('current data head is ${toHex(head)}, but read ${size} bytes')
            }
            let sign = (head & 0x08) == 0
            match(s){
                case 2 => Float16.fromBits(UInt16(bytes[0]) << 8 | UInt16(bytes[1])).toData()
                case 4 => Float32.fromBits(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])).toData()
                case 8 => Float32.fromBits(UInt32(bytes[0]) << 56 | UInt32(bytes[1]) << 48 | UInt32(bytes[2]) << 40 | UInt32(bytes[3]) << 32 | UInt32(bytes[4]) << 24 | UInt32(bytes[5]) << 16 | UInt32(bytes[6]) << 8 | UInt32(bytes[7])).toData()
                case _ => throw UnreachableException()
            }
        } else if (dataType == DataType.BIGINT.value) {
            readBigInt2(head, input).toData()
        } else if (dataType == DataType.DECIMAL1.value) {
            let valval = readBigInt1(head, input)
            let scale = Int32(decodeSizeOfEncoded(input))
            Decimal(valval, scale).toData()
        } else if (dataType == DataType.DECIMAL2.value) {
            let valval = readBigInt2(head, input)
            let scale = Int32(decodeSizeOfEncoded(input))
            Decimal(valval, scale).toData()
        } else if (dataType == DataType.DURATION1.value) {
            readDuration1(head, input).toData()
        } else if (dataType == DataType.DURATION2.value) {
            readDuration2(head, input).toData()
        } else if (dataType == DataType.DATETIME1.value) {
            (DateTime.UnixEpoch + readDuration1(head, input)).toData()
        } else if (dataType == DataType.DATETIME2.value) {
            (DateTime.UnixEpoch + readDuration2(head, input)).toData()
        } else if (dataType == DataType.COLLECTION.value) {
            let list = DataList()
            let s = Int64(head & 0x0f)
            bytes = Array<Byte>(s, repeat: 0)
            size = input.read(bytes)
            if(size < s){
                throw CodecException('current data head is ${toHex(head)}, but read ${size} bytes')
            }
            size = parseInt64(head, true, bytes)
            for(_ in 0 .. size){
                list.add(decodeData(input, fileThreshold))
            }
            list
        } else if (dataType == DataType.MAP.value) {
            let tuples = DataTuples()
            let s = Int64(head & 0x0f)
            bytes = Array<Byte>(s, repeat: 0)
            size = input.read(bytes)
            if(size < s) {
                throw CodecException('current data head is ${toHex(head)}, but read ${size} bytes')
            }
            size = parseInt64(head, true, bytes)
            for (_ in 0 .. size){
                let key = decodeData(input, fileThreshold)
                let value = decodeData(input, fileThreshold)
                tuples.add(key, value)
            }
            tuples
        } else if (dataType == DataType.OBJECT.value) {//todo
            let murmur = readBigInt2(head, input)
            let object = typeMurmurCreators[murmur]()
            let fieldSize = decodeSizeOfEncoded(input)
            for(_ in 0 .. size){
                let name = match(decodeData(input, fileThreshold)){
                    case x: DataString => x.data
                    case x => throw CodecException('current data head is ${toHex(head)} and it need a string as item name, but it is ${TypeInfo.of(x)}')
                }
                let value = decodeData(input, fileThreshold)
                object.set(name, value)
            }
            object
        } else if (dataType == DataType.INPUTSTREAM.value) {
            var s = Int64(head & 0x07)
            if(s == 0){
                s = 8
            }
            let f = head & 0x08
            bytes = Array<Byte>(s, repeat: 0)
            size = input.read(bytes)
            if(size < s){
                throw CodecException('current data head is ${toHex(head)}, but read size is ${size}')
            }
            size = parseInt64(head, true, bytes)
            if(size <= fileThreshold){
                let array = Array<Byte>(size, repeat: 0)
                size = input.read(array)
                if(size < s){
                    throw CodecException('current data head is ${toHex(head)}, but read size is ${size}')
                }
                return if(f == 0){
                    array.toData()
                }else{
                    let fileNameSize = decodeSizeOfEncoded(input)
                    bytes = Array<Byte>(fileNameSize, repeat: 0)
                    size = input.read(bytes)
                    if(size < fileNameSize){
                        throw CodecException('current data head is ${toHex(head)}, file name need ${fileNameSize} bytes, but read ${size}')
                    }
                    let fileName = String.fromUtf8(bytes)
                    let file = File.createTemp('/tmp/${fileName}')
                    file.write(array)
                    file.toData()
                }
            }
            let dir = '/tmp/${UUID.random()}'
            let file = File.createTemp(dir)
            var buffer = Array<Byte>(fileThreshold, repeat: 0)
            var readSize = 0
            while(true){
                readSize += input.read(buffer)
                file.write(buffer)
                if(readSize == size){
                    break
                }else if(readSize < size && size - readSize < buffer.size){
                    buffer = buffer[0 .. size - readSize]
                }
            }
            if(f != 0){
                let fileNameSize = decodeSizeOfEncoded(input)
                bytes = Array<Byte>(fileNameSize, repeat: 0)
                size = input.read(bytes)
                if(size < fileNameSize){
                    throw CodecException('current data head is ${toHex(head)}, file name need ${fileNameSize} bytes, but read ${size}')
                }
                let fileName = String.fromUtf8(bytes)
                let path = '${dir}/${fileName}'
                rename(file.info.path, to: Path(path), overwrite: false)
                file.close()
                return File(path, Read).toData()
            }
            file.toData()
        } else {
            throw UnreachableException()
        }
    }
    public func decode<T>(input: InputStream, fileThreshold!: Int64 = 1024 ** 2): ?T where T <: DataFields<T> {
        let d = T.tryFromData(decodeData(input, fileThreshold))
        match(d){
            case x: T => x
            case x: ?T => x
            case _ => throw UnreachableException()
        }
    }
    private func readDuration1(head: Byte, input: InputStream){
        let valval = readBigInt1(head, input)
        let seconds = valval / TEN_POW_NINE
        let nanos = valval - seconds * TEN_POW_NINE
        Duration.second * seconds.toInt64() + Duration.nanosecond * nanos.toInt64()
    }
    private func readDuration2(head: Byte, input: InputStream){
        let valval = readBigInt2(head, input)
        let seconds = valval / TEN_POW_NINE
        let nanos = valval - seconds * TEN_POW_NINE
        Duration.second * seconds.toInt64() + Duration.nanosecond * nanos.toInt64()
    }
    private func readBigInt1(head: Byte, input: InputStream){
        var s = Int64(head & 0x07)
        if(s == 0){
            s = 8
        }
        let bytes = Array<Byte>(s, repeat: 0)
        size = input.read(bytes)
        if(size < s){
            throw CodecException('current data head is ${toHex(head)}, but read ${size} bytes')
        }
        let sign = (head & 0x08) == 0
        BigInt(parseInt64(head, sign, bytes))
    }
    private func readBigInt2(head: Byte, input: InputStream){
        var s = Int64(head & 0x07)
        if(s == 0){
            s = 8
        }
        var bytes = Array<Byte>(s, repeat: 0)
        size = input.read(bytes)
        if(size < s){
            throw CodecException('current data head is ${toHex(head)}, but read ${size} bytes')
        }
        let sign = (head & 0x08) == 0
        s = parseInt64(head, true, bytes)
        let sizeBytes = bytes
        bytes = Array<Byte>(size, repeat: 0)
        size = input.read(bytes)
        if(size < s){
            throw CodecException('current data head is ${toHex(head)}, but read size of value is ${size}, need ${s}(bytes of need size: ${sizeBytes})')
        }
        BigInt(sign, bytes)
    }
}

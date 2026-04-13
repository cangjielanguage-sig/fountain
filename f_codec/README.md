# 编解码器
```cj
/**
编码器
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
*/
public interface Encoder {
    func encode(data: Data): Encoder
    func encode(data: DataAny): Encoder
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
/**
 * 解码器
 */
public interface Decoder {
    func decode<T>(input: InputStream): ?T where T <: DataFields<T>
}

public interface Codec <: Encoder & Decoder {}
```

## 数据类型
```cj
/**
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
*/
public enum DataType <: ToString {
    | NONE
    | STRING
    | BOOL
    | INT
    | FLOAT
    | BIGINT
    | DECIMAL1
    | DECIMAL2
    | DURATION1
    | DURATION2
    | DATETIME1
    | DATETIME2
    | COLLECTION
    | MAP
    | OBJECT
    | INPUTSTREAM
    
    public func toString(): String 
    public prop value: UInt8 
    public prop lowValue: UInt8 
    public static func convert(byte: Byte): DataType 
}
```

## 默认实现
```cj
public class DefaultCodec <: Codec
```

## 用法
```cj
import std.random.Random
import std.unittest.*
import std.unittest.testmacro.*

@Test
public class DefaultCodec_test {
    @TestCase
    public func testNone(): Unit {
        let encoder = DefaultCodec()
        let input = ByteBuffer()
        encoder.encodeNone().encodeNone().finish().copy(to: input, closeFromOnEnd: true, closeToOnEnd: false)
        let decoder = DefaultCodec()
        let bool = decoder.decode<Bool>(input)
        @Assert(bool, None<Bool>)
        let int = decoder.decode<Int64>(input)
        @Assert(int, None<Int64>)
    }
    @TestCase
    public func testBool(): Unit {
        let encoder = DefaultCodec()
        let input = ByteBuffer()
        encoder.encode(true).encode(false).finish().copy(to: input, closeFromOnEnd: true, closeToOnEnd: false)
        let decoder = DefaultCodec()
        var bool = decoder.decode<Bool>(input)
        @Assert(bool, true)
        bool = decoder.decode<Bool>(input)
        @Assert(bool, false)
    }
    @TestCase
    public func testInt64(): Unit {
        let encoder = DefaultCodec()
        let input = ByteBuffer()
        encoder
            .encode(0)
            .encode(1)
            .encode(-1)
            .encode(Int64.Min)
            .encode(Int64.Max)
            .encode(100)
            .encode(1000)
            .encode(255)
            .encode(65535)
            .encode(0xffffff)
            .encode(0xffffffff)
            .encode(0xffffffffff)
            .encode(0xffffffffffff)
            .encode(0xffffffffffffff)
            .encode(0x6fffffffffffffff)
            .encode(!0u64)
            .encode(!0u64 << 8)
            .encode(!0u64 << 16)
            .encode(!0u64 << 24)
            .encode(!0u64 << 32)
            .encode(!0u64 << 40)
            .encode(!0u64 << 48)
            .encode(!0u64 << 56)
            .encode(-1 << 8)
            .encode(-1 << 16)
            .encode(-1 << 24)
            .encode(-1 << 32)
            .encode(-1 << 40)
            .encode(-1 << 48)
            .encode(-1 << 56)
            .finish().copy(to: input, closeFromOnEnd: true, closeToOnEnd: false)
        let decoder = DefaultCodec()
        var int = decoder.decode<Int64>(input)
        @Assert(int, 0)
        int = decoder.decode<Int64>(input)
        @Assert(int, 1)
        int = decoder.decode<Int64>(input)
        @Assert(int, -1)
        int = decoder.decode<Int64>(input)
        @Assert(int, Int64.Min)
        int = decoder.decode<Int64>(input)
        @Assert(int, Int64.Max)
        int = decoder.decode<Int64>(input)
        @Assert(int, 100)
        int = decoder.decode<Int64>(input)
        @Assert(int, 1000)
        int = decoder.decode<Int64>(input)
        @Assert(int, 255)
        int = decoder.decode<Int64>(input)
        @Assert(int, 65535)
        int = decoder.decode<Int64>(input)
        @Assert(int, 0xffffff)
        int = decoder.decode<Int64>(input)
        @Assert(int, 0xffffffff)
        int = decoder.decode<Int64>(input)
        @Assert(int, 0xffffffffff)
        int = decoder.decode<Int64>(input)
        @Assert(int, 0xffffffffffff)
        int = decoder.decode<Int64>(input)
        @Assert(int, 0xffffffffffffff)
        int = decoder.decode<Int64>(input)
        @Assert(int, 0x6fffffffffffffff)
        var u64 = decoder.decode<UInt64>(input)
        @Assert(u64, !0u64)
        u64 = decoder.decode<UInt64>(input)
        @Assert(u64, !0u64 << 8)
        u64 = decoder.decode<UInt64>(input)
        @Assert(u64, !0u64 << 16)
        u64 = decoder.decode<UInt64>(input)
        @Assert(u64, !0u64 << 24)
        u64 = decoder.decode<UInt64>(input)
        @Assert(u64, !0u64 << 32)
        u64 = decoder.decode<UInt64>(input)
        @Assert(u64, !0u64 << 40)
        u64 = decoder.decode<UInt64>(input)
        @Assert(u64, !0u64 << 48)
        u64 = decoder.decode<UInt64>(input)
        @Assert(u64, !0u64 << 56)
        int = decoder.decode<Int64>(input)
        @Assert(int, -1 << 8)
        int = decoder.decode<Int64>(input)
        @Assert(int, -1 << 16)
        int = decoder.decode<Int64>(input)
        @Assert(int, -1 << 24)
        int = decoder.decode<Int64>(input)
        @Assert(int, -1 << 32)
        int = decoder.decode<Int64>(input)
        @Assert(int, -1 << 40)
        int = decoder.decode<Int64>(input)
        @Assert(int, -1 << 48)
        int = decoder.decode<Int64>(input)
        @Assert(int, -1 << 56)
    }
    
    @TestCase
    public func testBigInt(): Unit {
        let rand = Random()
        for(_ in 0 .. 10){
            let bytes = rand.nextBytes(32)
            let bytes1 = Array<Byte>(bytes.size){i => bytes[i]}
            let bytes2 = Array<Byte>(bytes.size){i => bytes[i]}
            let bytes3 = Array<Byte>(bytes.size){i => bytes[i]}
            let bytes4 = Array<Byte>(bytes.size){i => bytes[i]}
            let encoder = DefaultCodec()
            encoder.encode(BigInt(true, bytes1))
            let input = ByteBuffer()
            encoder.encode(BigInt(false, bytes2)).finish().copy(to: input, closeFromOnEnd: true, closeToOnEnd: false)
            let decoder = DefaultCodec()
            var bigint = decoder.decode<BigInt>(input)
            @Assert(bigint, BigInt(true, bytes3))
            bigint = decoder.decode<BigInt>(input)
            @Assert(bigint, BigInt(false, bytes4))
        }
    }
    @TestCase
    public func testFloat(): Unit {
        let rand = Random()
        for(i in 0 .. 100){
            let float1 = rand.nextFloat64() * 123412.0
            let float2 = rand.nextFloat64() * 125313452.0
            let input = ByteBuffer()
            DefaultCodec()
            .encode(float1).encode(float2)
            .encode(-float1).encode(-float2)
            .encode(0.0).encode(-0.0)
            .finish().copy(to: input, closeFromOnEnd: true, closeToOnEnd: false)
            let decoder = DefaultCodec()
            var float = decoder.decode<Float64>(input)
            @Assert(float, float1)
            float = decoder.decode<Float64>(input)
            @Assert(float, float2)
            float = decoder.decode<Float64>(input)
            @Assert(float, -float1)
            float = decoder.decode<Float64>(input)
            @Assert(float, -float2)
            float = decoder.decode<Float64>(input)
            @Assert(float, 0.0)
            float = decoder.decode<Float64>(input)
            @Assert(float, -0.0)
        }
    }
    @TestCase
    public func testDecimal1(): Unit {
        let rand = Random()
        for(i in 0 .. 100){
            let float1 = Decimal('${rand.nextInt64(10000)}.${rand.nextInt64(10000)}') 
            let float2 = Decimal('${rand.nextInt64(10000)}.${rand.nextInt64(10000)}')
            let input = ByteBuffer()
            DefaultCodec()
            .encode(float1).encode(float2)
            .encode(-float1).encode(-float2)
            .encode(Decimal('0.0')).encode(Decimal('-0.0'))
            .finish().copy(to: input, closeFromOnEnd: true, closeToOnEnd: false)
            let decoder = DefaultCodec()
            var float = decoder.decode<Decimal>(input)
            @Assert(float, float1)
            float = decoder.decode<Decimal>(input)
            @Assert(float, float2)
            float = decoder.decode<Decimal>(input)
            @Assert(float, -float1)
            float = decoder.decode<Decimal>(input)
            @Assert(float, -float2)
            float = decoder.decode<Decimal>(input)
            @Assert(float, Decimal('0.0'))
            float = decoder.decode<Decimal>(input)
            @Assert(float, Decimal('-0.0'))
        }
    }
    @TestCase
    public func testDecimal2(): Unit {
        let rand = Random()
        for(i in 0 .. 100){
            let float1 = Decimal(rand.nextFloat64() * 123412.0)
            let float2 = Decimal(rand.nextFloat64() * 125313452.0)
            let input = ByteBuffer()
            DefaultCodec()
            .encode(float1).encode(float2)
            .encode(-float1).encode(-float2)
            .encode(Decimal(0.0)).encode(Decimal(-0.0))
            .finish().copy(to: input, closeFromOnEnd: true, closeToOnEnd: false)
            let decoder = DefaultCodec()
            var float = decoder.decode<Decimal>(input)
            @Assert(float, float1)
            float = decoder.decode<Decimal>(input)
            @Assert(float, float2)
            float = decoder.decode<Decimal>(input)
            @Assert(float, -float1)
            float = decoder.decode<Decimal>(input)
            @Assert(float, -float2)
            float = decoder.decode<Decimal>(input)
            @Assert(float, Decimal(0.0))
            float = decoder.decode<Decimal>(input)
            @Assert(float, Decimal(-0.0))
        }
    }
    private static let hex = '0123456789abcdef'.toRuneArray()
    private static func toHex(bytes: Array<Byte>){
        func toHex(b: Byte): String {
            '${hex[Int64(b >> 4)]}${hex[Int64(b & 0x0f)]}'
        }
        let s = StringBuilder()
        for(b in bytes){
            s.append(toHex(b))
        }
        s.toString()
    }
    @TestCase
    public func testString(): Unit {
        let encoder = DefaultCodec()
        let input = ByteBuffer()
        encoder.encode('').finish().copy(to: input, closeFromOnEnd: true, closeToOnEnd: false)
        let s = DefaultCodec().decode<String>(input)
        @Assert(s, '')
        let rand = Random()
        for(i in 0 .. 100){
            let encoder = DefaultCodec()
            let decoder = DefaultCodec()
            let hex = ['','']
            for(i in 0 .. 2){
                let size = if(let s <- rand.nextInt32(128)) {
                    if(s < 0){
                        -s
                    } else if (s == 0) {
                        1i32
                    } else{
                        s
                    }
                }else{
                    1i32
                }
                let bytes = rand.nextBytes(size)
                hex[i] = toHex(bytes)
                encoder.encode(hex[i])
            }
            let input = ByteBuffer()
            encoder.finish().copy(to: input, closeFromOnEnd: true, closeToOnEnd: false)
            for(i in 0 .. 2){
                let s = decoder.decode<String>(input)
                @Assert(s, hex[i])
            }
        }
    }
    @TestCase
    public func testDuration(): Unit {
        let encoder = DefaultCodec()
        let input = ByteBuffer()
        encoder.encode(Duration.Zero)
                   .encode(Duration.nanosecond * 2411342152354)
                   .encode(Duration.nanosecond * -2411342152354)
                   .encode(Duration.Max)
                   .encode(Duration.Min)
                   .finish().copy(to: input, closeFromOnEnd: true, closeToOnEnd: false)
        let decoder = DefaultCodec()
        var duration = decoder.decode<Duration>(input)
        @Assert(duration, Duration.Zero)
        duration = decoder.decode<Duration>(input)
        @Assert(duration, Duration.nanosecond * 2411342152354)
        duration = decoder.decode<Duration>(input)
        @Assert(duration, Duration.nanosecond * -2411342152354)
        duration = decoder.decode<Duration>(input)
        @Assert(duration, Duration.Max)
        duration = decoder.decode<Duration>(input)
        @Assert(duration, Duration.Min)
    }
    @TestCase
    public func testDateTime(): Unit {
        let now = DateTime.now()
        let encoder = DefaultCodec()
        let input = ByteBuffer()
        encoder.encode(now)
                   .encode(DateTime.UnixEpoch)
                   .encode(DateTime.UnixEpoch + Duration.nanosecond * 2411342152354)
                   .encode(DateTime.UnixEpoch + Duration.nanosecond * -2411342152354)
                   .finish().copy(to: input, closeFromOnEnd: true, closeToOnEnd: false)
        let decoder = DefaultCodec()
        var datetime = decoder.decode<DateTime>(input)
        @Assert(datetime, now)
        datetime = decoder.decode<DateTime>(input)
        @Assert(datetime, DateTime.UnixEpoch)
        datetime = decoder.decode<DateTime>(input)
        @Assert(datetime, DateTime.UnixEpoch + Duration.nanosecond * 2411342152354)
        datetime = decoder.decode<DateTime>(input)
        @Assert(datetime, DateTime.UnixEpoch + Duration.nanosecond * -2411342152354)
    }
    @TestCase
    public func testBytes(): Unit {
        let rand = Random()
        func make(){
            let s = if(let s <- rand.nextInt32(128)) {
                if(s < 0){
                    -s
                } else if (s == 0){
                    1i32
                } else {
                    s
                }
            }else{
                1i32
            }
            rand.nextBytes(s)
        }
        for(i in 0 .. 100){
            let bytes1 = make()
            let bytes2 = make()
            let input = ByteBuffer()
            DefaultCodec().encode(bytes1).encode(bytes2).finish().copy(to: input, closeFromOnEnd: true, closeToOnEnd: false)
            let decoder = DefaultCodec()
            var bytes = decoder.decode<Array<Byte>>(input)
            @Assert(bytes, bytes1)
            bytes = decoder.decode<Array<Byte>>(input)
            @Assert(bytes, bytes2)
        }
    }
    // @TestCase
    // public func testFile(): Unit {
    //     let rand = Random()
    //     func make(){
    //         let s = if(let s <- rand.nextInt32(128)) {
    //             if(s < 0){
    //                 -s
    //             } else if (s == 0){
    //                 1i32
    //             } else {
    //                 s
    //             }
    //         }else{
    //             1i32
    //         }
    //         rand.nextBytes(s)
    //     }
    //     for(i in 0 .. 2){
    //         let bytes1 = make()
    //         let bytes2 = make()
    //         let file1 = File.createTemp('/tmp')
    //         let file2 = File.createTemp('/tmp')
    //         file1.write(bytes1)
    //         file2.write(bytes2)
    //         file1.flush()
    //         file2.flush()
    //         file1.seek(SeekPosition.Begin(0))
    //         file2.seek(SeekPosition.Begin(0))
    //         let input = ByteBuffer()
    //         DefaultCodec().encode(file1).encode(file2).finish().copy(to: input, closeFromOnEnd: true, closeToOnEnd: false)
    //         let decoder = DefaultCodec()
    //         var file = decoder.decode<File>(input)
    //         @Assert(file?.info.name, file1.info.name)
    //         file = decoder.decode<File>(input)
    //         @Assert(file?.info.name, file2.info.name)
    //     }
    // }
    @TestCase
    public func testList(): Unit {
        let list1 = ArrayList<Int64>([12,2,3,3,4344,51])
        let list2 = ArrayList<String>(['14531', '2q95504', 'zxca', 'asdf4', '5asdf'])
        let input = ByteBuffer()
        DefaultCodec().encode(list1).encode(list2).finish().copy(to: input, closeFromOnEnd: true, closeToOnEnd: false)
        let decoder = DefaultCodec()
        let ints = decoder.decode<ArrayList<Int64>>(input) ?? ArrayList<Int64>()
        @Assert(ints.size, list1.size)
        for(i in 0 .. ints.size){
            @Assert(ints[i], list1[i])
        }
        let strings = decoder.decode<ArrayList<String>>(input) ?? ArrayList<String>()
        @Assert(strings.size, list2.size)
        for(i in 0 .. strings.size){
            @Assert(strings[i], list2[i])
        }
    }
    @TestCase
    public func testMap(): Unit {
        let map1 = HashMap<Int64, String>([(1234, 'awrqewr'), (123535, 'xzcvaq'), (8096, 'sdfgp'), (84234, '8ofi398ruio')])
        let map2 = HashMap<String, Int64>([('14531', 31351), ('2q95504', 830951), ('zxca', 348301), ('asdf4', 5127), ('5asdf', 8301234)])
        let input = ByteBuffer()
        DefaultCodec().encode(map1).encode(map2).finish().copy(to: input, closeFromOnEnd: true, closeToOnEnd: false)
        let decoder = DefaultCodec()
        let m1 = decoder.decode<HashMap<Int64, String>>(input) ?? HashMap<Int64, String>()
        @Assert(m1.size, map1.size)
        let map1itr = map1.iterator()
        let m1itr = m1.iterator()
        while(let Some((k1, v1)) <- m1itr.next() && let Some((k2, v2)) <- map1itr.next()){
            @Assert(k1, k2)
            @Assert(v1, v2)
        }
        let m2 = decoder.decode<HashMap<String, Int64>>(input) ?? HashMap<String, Int64>()
        @Assert(m2.size, map2.size)
        let map2itr = map2.iterator()
        let m2itr = m2.iterator()
        while(let Some((k1, v1)) <- m2itr.next() && let Some((k2, v2)) <- map2itr.next()){
            @Assert(k1, k2)
            @Assert(v1, v2)
        }
    }
    @TestCase
    public func testObject(): Unit {
        let object = TestObject(124, 'asdfas')
        let input = ByteBuffer()
        DefaultCodec().encode(object).finish().copy(to: input, closeFromOnEnd: true, closeToOnEnd: false)
        let decoder = DefaultCodec()
        let o = decoder.decode<TestObject>(input)
        @Assert(o, object)
    }
}
```
```cj
import fountain::f_data.macros.*

@DataAssist[props fields equal tostring]
public class TestObject {
    private var i: Int64 = 0
    private var s: String = ''
    public init(){}
    public init(i: Int64, s: String){
        this.i = i
        this.s = s
    }
}
```
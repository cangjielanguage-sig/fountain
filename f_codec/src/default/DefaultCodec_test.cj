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

import std.random.Random
import std.unittest.*
import std.unittest.testmacro.*

@Test
public class DefaultCodec_test {
    @TestCase
    public func testNone(): Unit {
        let encoder = DefaultCodec()
        let input = ByteBuffer()
        encoder.encodeNone().encodeNone().finish().copy(to: input, closeOnEnd: true)
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
        encoder.encode(true).encode(false).finish().copy(to: input, closeOnEnd: true)
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
            .finish().copy(to: input, closeOnEnd: true)
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
            encoder.encode(BigInt(false, bytes2)).finish().copy(to: input, closeOnEnd: true)
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
            .finish().copy(to: input, closeOnEnd: true)
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
            .finish().copy(to: input, closeOnEnd: true)
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
            .finish().copy(to: input, closeOnEnd: true)
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
        encoder.encode('').finish().copy(to: input, closeOnEnd: true)
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
            encoder.finish().copy(to: input, closeOnEnd: true)
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
                   .finish().copy(to: input, closeOnEnd: true)
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
                   .finish().copy(to: input, closeOnEnd: true)
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
    //         DefaultCodec().encode(file1).encode(file2).finish().copy(to: input, closeOnEnd: true)
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
        DefaultCodec().encode(list1).encode(list2).finish().copy(to: input, closeOnEnd: true)
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
        DefaultCodec().encode(map1).encode(map2).finish().copy(to: input, closeOnEnd: true)
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
        DefaultCodec().encode(object).finish().copy(to: input, closeOnEnd: true)
        let decoder = DefaultCodec()
        let o = decoder.decode<TestObject>(input)
        @Assert(o, object)
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
            DefaultCodec().encode(bytes1).finish().copy(to: input, closeOnEnd: true)
            let decoder = DefaultCodec()
            println('~~~~~~~~~~~~~~~~~~~~~~~~~~~~   ${bytes1}')
            println('AAAAAAAAAAAAAAAAAAAAAAAAAAAA   ${input.bytes()}')
            input.seek(Begin(0))
            var bytes = decoder.decode<Array<Byte>>(input)
            println('AAAAAAAAAAAAAAAAAAAAAAAAAAAA ${i} ${bytes1.size} ${bytes?.size}')
            println(bytes1)
            println(bytes)
            println('AAAAAAAAAAAAAAAAAAAAAAAAAAAA')
            @Assert(bytes, bytes1)
        }
    }
}

/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_util

import std.convert.Parsable
import std.fs.{File, Directory, OpenMode}
import std.io.SeekPosition
import std.math.numeric.BigInt
import std.process.Process
import std.sync.{AtomicUInt16, AtomicInt64, ReentrantMutex}
import std.time.{TimeZone, DateTime}
import crypto.crypto.*
import crypto.digest.{MD5, SHA1}
import f_base.HashBuilder
import f_exception.UnreachableException
import f_util.exception.UUIDException

/**
 * reference https://www.ietf.org/archive/id/draft-ietf-uuidrev-rfc4122bis-00.html
 */
public struct UUID <: Hashable & Comparable<UUID> & ToString & Parsable<UUID> {
    private let h: Int64
    UUID(private let values!: Array<Byte> = Array<Byte>(16, repeat: 0)) {
        h = HashBuilder().append<Byte>(values).finish()
    }

    public func hashCode(): Int64 {
        h
    }
    public operator func ==(other: UUID): Bool {
        h == other.h && values == other.values
    }
    public operator func !=(other: UUID): Bool {
        !(this == other)
    }
    public func compare(other: UUID): Ordering {
        let v1 = this.values
        let v2 = other.values
        var i = 0
        while (i < 16) {
            match (v1[i].compare(v2[i])) {
                case EQ => i++
                case x => return x
            }
        }
        return EQ
    }

    public static let Nil = UUID()
    public static let Max = UUID(values: Array<Byte>(16, repeat: 0xff))

    private static let hex = [r'0', r'1', r'2', r'3', r'4', r'5', r'6', r'7', r'8', r'9', r'a', r'b', r'c', r'd', r'e', r'f']
    public func toString(): String {
        toString(true)
    }
    private func toString(withDash: Bool){
        //00 00 00 00-00 00-00 00-00 00-00 00 00 00 00 00
        //0  1  2  3  4  5  6  7  8  9  10 11 12 13 14 15
        let builder = StringBuilder()
        var i = 0
        while (i < values.size) {
            let v = values[i]
            builder.append(hex[Int64((v >> 4) & 0xf)])
            builder.append(hex[Int64(v & 0xf)])
            if (withDash && (i == 3 || i == 5 || i == 7 || i == 9)) {
                builder.append(r'-')
            }
            i++
        }
        builder.toString()
    }
    public func toString(base: Int64){
        if(base == 16){
            return toString(false)
        }
        BigInt(true, values).toString(base)
    }
    public func toHexString(){
        toString(16)
    }
    public prop version: Int64 {
        get() {
            Int64(values[7] >> 4)
        }
    }
    public prop timestampNanos: Int64 {
        get() {
            var n = 0
            match (version) {
                case 1 =>
                    n |= Int64(values[6] & 0xf)
                    n <<= 8
                    n |= Int64(values[7])
                    n <<= 8
                    n |= Int64(values[4])
                    n <<= 8
                    n |= Int64(values[5])
                    n <<= 8
                    n |= Int64(values[0])
                    n <<= 8
                    n |= Int64(values[1])
                    n <<= 8
                    n |= Int64(values[2])
                    n <<= 8
                    n |= Int64(values[3])
                case 6 =>
                    n |= Int64(values[0])
                    n <<= 8
                    n |= Int64(values[1])
                    n <<= 8
                    n |= Int64(values[2])
                    n <<= 8
                    n |= Int64(values[3])
                    n <<= 8
                    n |= Int64(values[4])
                    n <<= 8
                    n |= Int64(values[5])
                    n <<= 8
                    n |= Int64(values[6] & 0xf)
                    n <<= 8
                    n |= Int64(values[7])
                case 7 =>
                    n |= Int64(values[0])
                    n <<= 8
                    n |= Int64(values[1])
                    n <<= 8
                    n |= Int64(values[2])
                    n <<= 8
                    n |= Int64(values[3])
                    n <<= 8
                    n |= Int64(values[4])
                    n <<= 8
                    n |= Int64(values[5])
                    n <<= 8
                    n |= Int64(values[6] & 0xf)
                    n <<= 8
                    n |= Int64(values[7])
                    n * 10000
                case _ => 0
            }
            n * 100
        }
    }
    public prop timestamp: DateTime {
        get() {
            let v = version
            match (v) {
                case 7 => DateTime.UnixEpoch
                case 1 | 6 => TimestampSequenceBuilder.timeStart
                case _ => throw UUIDException("current version is without timestamp and version is ${v}")
            } + timestampNanos * Duration.nanosecond
        }
    }
    public prop propiant: Int64 {
        get() {
            Int64(values[8] >> 6)
        }
    }
    public static func parse(uuid: String): UUID {
        tryParse(uuid).getOrThrow {IllegalArgumentException("error uuid ${uuid}")}
    }
    public static func tryParse(uuid: String): ?UUID {
        func doParse(c: Rune, i: Int64): UInt8 {
            match (c) {
                case r'0' => 0x0
                case r'1' => 0x1
                case r'2' => 0x2
                case r'3' => 0x3
                case r'4' => 0x4
                case r'5' => 0x5
                case r'6' => 0x6
                case r'7' => 0x7
                case r'8' => 0x8
                case r'9' => 0x9
                case r'a' => 0xa
                case r'b' => 0xb
                case r'c' => 0xc
                case r'd' => 0xd
                case r'e' => 0xe
                case r'f' => 0xf
                case r'-' where i == 4 || i == 6 || i == 8 || i == 10 =>
                //00 00 00 00-00 00-00 00-00 00-00 00 00 00 00 00
                //0  2  4  6  9  11 14 16 19 21 24 26 28 30 32 35 Rune
                //0  1  2  3  4  5  6  7  8  9  10 11 12 13 14 15 array index
                16
                case _ => 17
            }
        }
        var values = Array<Byte>(16, repeat: 0)
        let iterator = uuid.runes()
        var i = 0
        while (i < 16) {
            var c = iterator.next()
            let b1 = match (c) {
                case Some(x) => doParse(x, i)
                case _ => return None<UUID>
            }
            if (b1 == 16) {
                continue
            } else if (b1 == 17) {
                return None<UUID>
            }
            c = iterator.next()
            let b2 = match (c) {
                case Some(x) => doParse(x, i)
                case _ => return None<UUID>
            }
            if (b2 == 16 || b2 == 17) {
                return None<UUID>
            }
            values[i] = (b1 << 4) | b2
            i++
        }
        if (i == 16 && iterator.next().isNone()) {
            UUID(values: values)
        } else {
            None<UUID>
        }
    }
    /**
       version 1
       0                   1                   2                   3
       0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
       |                          time_low                             |
       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
       |       time_mid                | ver   | time_hi_and_version   |
       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
       |clk_seq_hi_res |  clk_seq_low  |         node (0-1)            |
       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
       |                         node (2-5)                            |
       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
     */
    /**
       version 6
       0                   1                   2                   3
       0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
       |                           time_high                           |
       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
       |           time_mid            | ver   | time_low_and_version  |
       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
       |clk_seq_hi_res |  clk_seq_low  |         node (0-1)            |
       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
       |                         node (2-5)                            |
       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
     */
    public static func timeBased(timeLowFirst!: Bool = false): TimeBasedUUIDBuilder {
        TimeBasedUUIDBuilder(timeLowFirst)
    }
    /**
       0                   1                   2                   3
       0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
       |                            md5_high                           |
       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
       |          md5_high             |  ver  |       md5_mid         |
       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
       |var|                        md5_low                            |
       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
       |                            md5_low                            |
       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
     */
    public static func md5(value: String): UUID {
        md5(value.toArray())
    }
    public static func md5(value: Array<Byte>): UUID {
        let md5 = MD5()
        md5.write(value)
        var md = md5.finish()
        md[6] &= 0xf
        md[6] |= 3 << 4
        md[8] &= 0x3f
        md[8] |= 2 << 6
        UUID(values: md)
    }
    public static func random(): UUID {
        let rand = SecureRandom().nextBytes(16)
        rand[6] &= 0xf
        rand[6] &= 4 << 4
        rand[8] &= 0x3f
        rand[8] &= 2 << 6
        UUID(values: rand)
    }
    /**
       0                   1                   2                   3
       0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
       |                            sha_high                           |
       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
       |          sha_high             |  ver  |       sha_mid         |
       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
       |var|                        sha_low                            |
       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
       |                            sha_low                            |
       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
       最后的sha_low在原文是md5_low，此处应该是一个错误
     */
    public static func sha1(value: String): UUID {
        sha1(value.toArray())
    }
    public static func sha1(value: Array<Byte>): UUID {
        let sha1 = SHA1()
        sha1.write(value)
        let sha = sha1.finish()
        let values = Array<Byte>(16) {
            i => if (i < 6) {
                sha[i]
            } else if (i == 6) {
                (sha[18] & 0xf) | (5 << 4)
            } else if (i == 7) {
                sha[19]
            } else if (i == 8) {
                sha[8] & 0x3f | (2 << 6)
            } else {
                sha[i]
            }
        }
        UUID(values: values)
    }
    /**
       0                   1                   2                   3
       0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
       |                           unix_ts_ms                          |
       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
       |          unix_ts_ms           |  ver  |       rand_a          |
       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
       |var|                        rand_b                             |
       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
       |                            rand_b                             |
       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
     */
    public static func unixTimeBased(): UUID {
        let millis = (DateTime.now() - DateTime.UnixEpoch).toMilliseconds()
        let rand = SecureRandom().nextBytes(10)
        let values = Array<Byte>(16) {
            i => if (i < 6) {
                UInt8((millis >> (7 - i) * 8) & 0xff)
            } else if (i == 6) {
                (rand[0] & 0xf) | (7 << 4)
            } else if (i == 7) {
                rand[1]
            } else if (i == 8) {
                (rand[2] & 0x3f) | (2 << 6)
            } else {
                rand[i - 6]
            }
        }
        UUID(values: values)
    }
    /**
       0                   1                   2                   3
       0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
       |                           custom_a                            |
       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
       |          custom_a             |  ver  |       custom_b        |
       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
       |var|                       custom_c                            |
       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
       |                           custom_c                            |
       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
       只取参数的前16字节
     */
    public static func custom(values: Array<Byte>): UUID {
        let s = values.size
        let val = Array<Byte>(16) {
            i =>
            let val = if (i < s) {
                values[i]
            } else {
                0u8
            }
            if (i == 6) {
                (val & 0xf) | (8 << 4)
            } else if (i == 8) {
                (val & 0x3f) | (2 << 6)
            } else {
                val
            }
        }
        UUID(values: val)
    }
}
public class TimeBasedUUIDBuilder {
    private let version: Byte
    private var timestamp: Int64 = 0
    private var seq: UInt16 = 0
    init(timeLowFirst: Bool) {
        version = if (timeLowFirst) {
            1
        } else {
            6
        }
    }
    public prop randomSeq: TimeBasedUUIDBuilder {
        get() {
            genTimestampAndSequence(true)
            this
        }
    }
    public prop serialSeq: TimeBasedUUIDBuilder {
        get() {
            genTimestampAndSequence(false)
            this
        }
    }
    private func genTimestampAndSequence(randomSeq: Bool) {
        while (timestamp == 0 || seq == 0) {
            (timestamp, seq) = TimestampSequenceBuilder.timestampAndSequence(randomSeq)
        }
    }
    public func ether(ether: String): UUID {
        //00:00:00:00:00:00
        //0  1  2  3  4  5
        //0  3  6  9  12 15
        let itr = ether.runes()
        func parse(ch: ?Rune): Byte {
            match (ch) {
                case Some(c) => match (c) {
                    case r'0' => 0
                    case r'1' => 1
                    case r'2' => 2
                    case r'3' => 3
                    case r'4' => 4
                    case r'5' => 5
                    case r'6' => 6
                    case r'7' => 7
                    case r'8' => 8
                    case r'9' => 9
                    case r'a' | r'A' => 10
                    case r'b' | r'B' => 11
                    case r'c' | r'C' => 12
                    case r'd' | r'D' => 13
                    case r'e' | r'E' => 14
                    case r'f' | r'F' => 15
                    case _ => throw UnreachableException()
                }
                case _ => throw UnreachableException()
            }
        }
        generate {
            i =>
            var b = (parse(itr.next()) << 4) | (parse(itr.next()))
            if (i < 5) {
                itr.next()
            }
            b
        }
    }
    public func node(node: Int64): UUID {
        generate {
            i => UInt8((node >> (Int64(5 - i) * 8)) & 0xff)
        }
    }
    public func node(node: UInt64): UUID {
        generate {
            i => UInt8((node >> (UInt64(5 - i) * 8)) & 0xff)
        }
    }
    public func randomNode(): UUID {
        node(SecureRandom().nextBytes(6))
    }
    public func node(node: Array<Byte>): UUID {
        generate {i => node[i]}
    }
    private func generate(node: (Int64) -> Byte): UUID {
        let timeFn = if (version == 1) {
            timeLowFirst(timestamp)
        } else {
            timeHighFirst(timestamp)
        }
        UUID(
            values: Array<UInt8>(16) {
                i => if (i < 8) {
                    timeFn(i)
                } else if (i == 8) {
                    UInt8((seq >> 8) & 0x3f) | (0x2 << 6)
                } else if (i == 9) {
                    UInt8(seq & 0xff)
                } else {
                    node(i - 10)
                }
            }
        )
    }
    private func timeLowFirst(timestamp: Int64): (Int64) -> Byte {
        {
            idx => if (idx < 4) {
                UInt8((timestamp >> ((3 - idx) * 8)) & 0xff)
            } else if (idx == 4) {
                UInt8((timestamp >> 32) & 0xff)
            } else if (idx == 5) {
                UInt8((timestamp >> 40) & 0xff)
            } else if (idx == 6) {
                UInt8((timestamp >> 48) & 0xf) | version
            } else {
                UInt8((timestamp >> 56) & 0xff)
            }
        }
    }
    public func timeHighFirst(timestamp: Int64): (Int64) -> Byte {
        {
            idx => if (idx < 4) {
                UInt8((timestamp >> ((7 - idx) * 8)) & 0xff)
            } else if (idx == 4) {
                UInt8((timestamp >> 24) & 0xff)
            } else if (idx == 5) {
                UInt8((timestamp >> 16) & 0xff)
            } else if (idx == 6) {
                UInt8((timestamp >> 8) & 0xf) | version
            } else {
                UInt8(timestamp & 0xff)
            }
        }
    }
}
public class TimestampSequenceBuilder {
    private init() {}
    private static var seqGen: (Int64) -> UInt16 = {
         =>
        let seq = AtomicUInt16(0)
        {t: Int64 => seq.fetchAdd(1)}
    }()
    public static func registerSequenceGenerator(generator: (Int64) -> UInt16) {
        seqGen = generator
    }
    public static func registerFileSequenceGenerator() {
        let serial = AtomicUInt16(0)
        let dir = Directory.createTemp('/tmp')
        let file = File("${dir}/${serial.fetchAdd(1)}", OpenMode.Write)
        Process.current.atExit{file.close()}
        seqGen = {
            timestamp =>
            var seq: UInt16 = 0
            var bytes = Array<Byte>(8, repeat: 0)
            file.read(bytes)
            var storedNanos = 0
            var i = 0
            while (i < 8) {
                storedNanos |= Int64(bytes[i]) << ((7 - i) * 8)
                i++
            }
            if (storedNanos >= timestamp) {
                seq = 0u16
            } else {
                i = 0
                while (i < 8) {
                    bytes[i] = UInt8((timestamp >> ((7 - i) * 8)) & 0xff)
                }
                file.seek(Begin(0))
                file.write(bytes)
                seq = SecureRandom().nextUInt16()
            }
            seq
        }
    }
    public static func registerSequenceGenerator() {
        let lastNanos = AtomicInt64(0)
        seqGen = {
            timestamp =>
            let last = lastNanos.load()
            if (last >= timestamp) {
                return 0
            } else if (lastNanos.compareAndSwap(last, timestamp)) {
                return SecureRandom().nextUInt16()
            } else {
                return 0
            }
        }
    }
    static let timeStart = DateTime.of(year: 1582, month: 10, dayOfMonth: 15, hour: 0, minute: 0, second: 0,
        nanosecond: 0, timeZone: TimeZone.UTC)
    private static let mutex = ReentrantMutex()

    static func timestampAndSequence(randomSeq: Bool): (Int64, UInt16) {
        synchronized(mutex) {
            let timestamp = (DateTime.now() - timeStart).toNanoseconds() / 100
            if (randomSeq) {
                (timestamp, SecureRandom().nextUInt16())
            } else {
                (timestamp, seqGen(timestamp))
            }
        }
    }
}

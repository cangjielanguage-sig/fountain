/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_base

public import std.math.*
public import std.math.numeric.*

/**可执行加法运算*/

public interface Number<T> <: Negativable<T> & Addable<T> & Subable<T> & Mulable<T> & Divable<T> & Cmpable<T> & Eqable<T>
    & ToString where T <: Number<T> & ToString {
    static prop bytes: Int64
    static prop zero: T
    static prop one: T
    static prop ten: T

    static prop Max: T
    static prop Min: T
}

public interface Integer<T> <: Number<T> & Modable<T> & BitAndable<T> & BitOrable<T> & BitXorable<T> & LeftShiftable<T> &
    RightShiftable<T> where T <: Integer<T> {
    operator func %(right: T): T
    operator func &(right: T): T
    operator func |(right: T): T
    operator func ^(right: T): T
    operator func >>(right: T): T
    operator func <<(right: T): T
    operator func !(): T
    func numberOfLeadingZeros(): T
    prop isOdd: Bool {
        get() {
            !isEven
        }
    }
    prop isEven: Bool
}
public interface SignedInteger<S, T> <: Integer<S> where S <: SignedInteger<S, T>, T <: UnsignedInteger<T, S>{
    func toUInt(): T
}
public interface UnsignedInteger<S, T> <: Integer<S> where S <: UnsignedInteger<S, T>, T <: SignedInteger<T, S> {
    func toInt(): T
}
public interface Float<T> <: Number<T> where T <: Float<T> {
    static prop NaN: T
    static prop Inf: T
    static prop PI: T
    static prop E: T
    static prop MinDenormal: T
    static prop MinNormal: T
    static prop NegInf: T{
        get(){
            -Inf
        }
    }
}

extend Int8 <: SignedInteger<Int8, UInt8> {
    public static prop bytes: Int64 {
        get() {
            1
        }
    }
    public static prop zero: Int8 {
        get() {
            0
        }
    }
    public static prop one: Int8 {
        get() {
            1
        }
    }
    public static prop ten: Int8 {
        get() {
            10
        }
    }
    public static prop max: Int8 {
        get() {
            Int8.Max
        }
    }
    public static prop min: Int8 {
        get() {
            Int8.Min
        }
    }
    public func numberOfLeadingZeros(): Int8 {
        if (this < 0) {
            return 0
        } else if (this == 0) {
            return 8
        }
        var i = this
        var n = 7i8
        if (i >= 1 << 4) {
            n -= 4
            i >>= 4
        }
        if (i >= 1 << 2) {
            n -= 2
            i >>= 2
        }
        return n - (i >> 1)
    }
    public prop isEven: Bool {
        get() {
            (this & 1) == 0
        }
    }
    public prop isOdd: Bool {
        get(){
            !isEven
        }
    }
    
    @OverflowWrapping
    public func toUInt(): UInt8 {
        UInt8(this & 0x7f) | UInt8(this & (1 << 7))
    }
}
extend Int16 <: SignedInteger<Int16, UInt16> {
    public static prop bytes: Int64 {
        get() {
            2
        }
    }
    public static prop zero: Int16 {
        get() {
            0
        }
    }
    public static prop one: Int16 {
        get() {
            1
        }
    }
    public static prop ten: Int16 {
        get() {
            10
        }
    }
    public static prop max: Int16 {
        get() {
            Int16.Max
        }
    }
    public static prop min: Int16 {
        get() {
            Int16.Min
        }
    }
    public func numberOfLeadingZeros(): Int16 {
        if (this < 0) {
            return 0
        } else if (this == 0) {
            return 16
        }
        var i = this
        var n = 15i16
        if (i >= 1 << 8) {
            n -= 8
            i >>= 8
        }
        if (i >= 1 << 4) {
            n -= 4
            i >>= 4
        }
        if (i >= 1 << 2) {
            n -= 2
            i >>= 2
        }
        return n - (i >> 1)
    }
    public prop isEven: Bool {
        get() {
            (this & 1) == 0
        }
    }
    public prop isOdd: Bool {
        get(){
            !isEven
        }
    }
    @OverflowWrapping
    public func toUInt(): UInt16 {
        UInt16(this & 0x7f_ff) | UInt16(this & (1 << 15))
    }
}
extend Int32 <: SignedInteger<Int32, UInt32> {
    public static prop bytes: Int64 {
        get() {
            4
        }
    }
    public static prop zero: Int32 {
        get() {
            0
        }
    }
    public static prop one: Int32 {
        get() {
            1
        }
    }
    public static prop ten: Int32 {
        get() {
            10
        }
    }
    public static prop max: Int32 {
        get() {
            Int32.Max
        }
    }
    public static prop min: Int32 {
        get() {
            Int32.Min
        }
    }
    public func numberOfLeadingZeros(): Int32 {
        if (this < 0) {
            return 0
        } else if (this == 0) {
            return 32
        }
        var i = this
        var n = 31i32

        if (i >= 1 << 16) {
            n -= 16
            i >>= 16
        }
        if (i >= 1 << 8) {
            n -= 8
            i >>= 8
        }
        if (i >= 1 << 4) {
            n -= 4
            i >>= 4
        }
        if (i >= 1 << 2) {
            n -= 2
            i >>= 2
        }
        return n - (i >> 1)
    }
    public prop isEven: Bool {
        get() {
            (this & 1) == 0
        }
    }
    public prop isOdd: Bool {
        get(){
            !isEven
        }
    }
    @OverflowWrapping
    public func toUInt(): UInt32{
        UInt32(this & 0x7fff_ffff) | UInt32(this & (1 << 31))
    }
}
extend Int64 <: SignedInteger<Int64, UInt64> {
    public static prop bytes: Int64 {
        get() {
            8
        }
    }
    public static prop zero: Int64 {
        get() {
            0
        }
    }
    public static prop one: Int64 {
        get() {
            1
        }
    }
    public static prop ten: Int64 {
        get() {
            10
        }
    }
    public static prop max: Int64 {
        get() {
            Int64.Max
        }
    }
    public static prop min: Int64 {
        get() {
            Int64.Min
        }
    }
    public func numberOfLeadingZeros(): Int64 {
        if (this < 0) {
            return 0
        } else if (this == 0) {
            return 64
        }
        var i = this
        var n = 63

        if (i >= 1 << 32) {
            n -= 32
            i >>= 32
        }
        if (i >= 1 << 16) {
            n -= 16
            i >>= 16
        }
        if (i >= 1 << 8) {
            n -= 8
            i >>= 8
        }
        if (i >= 1 << 4) {
            n -= 4
            i >>= 4
        }
        if (i >= 1 << 2) {
            n -= 2
            i >>= 2
        }
        return n - (i >> 1)
    }
    public prop isEven: Bool {
        get() {
            (this & 1) == 0
        }
    }
    public prop isOdd: Bool {
        get(){
            !isEven
        }
    }
    @OverflowWrapping
    public func toUInt(): UInt64 {
        UInt64(this & 0x7fff_ffff_ffff_ffff) | UInt64(this & (1 << 63))
    }
}

extend UInt8 <: UnsignedInteger<UInt8, Int8> {
    public static prop bytes: Int64 {
        get() {
            1
        }
    }
    public static prop zero: UInt8 {
        get() {
            0
        }
    }
    public static prop one: UInt8 {
        get() {
            1
        }
    }
    public static prop ten: UInt8 {
        get() {
            10
        }
    }
    public static prop max: UInt8 {
        get() {
            UInt8.Max
        }
    }
    public static prop min: UInt8 {
        get() {
            UInt8.Min
        }
    }
    public func numberOfLeadingZeros(): UInt8 {
        if (this == 0) {
            return 8
        }
        var i = this
        var n = 7u8

        if (i >= 1 << 4) {
            n -= 4
            i >>= 4
        }
        if (i >= 1 << 2) {
            n -= 2
            i >>= 2
        }
        return n - (i >> 1)
    }
    public prop isEven: Bool {
        get() {
            (this & 1) == 0
        }
    }
    public prop isOdd: Bool {
        get(){
            !isEven
        }
    }
    @OverflowWrapping
    public func toInt(): Int8{
        Int8(this & 0x7f) | Int8(this & (1 << 7))
    }
}
extend UInt16 <: UnsignedInteger<UInt16, Int16> {
    public static prop bytes: Int64 {
        get() {
            2
        }
    }
    public static prop zero: UInt16 {
        get() {
            0
        }
    }
    public static prop one: UInt16 {
        get() {
            1
        }
    }
    public static prop ten: UInt16 {
        get() {
            10
        }
    }
    public static prop max: UInt16 {
        get() {
            UInt16.Max
        }
    }
    public static prop min: UInt16 {
        get() {
            UInt16.Min
        }
    }
    public func numberOfLeadingZeros(): UInt16 {
        if (this == 0) {
            return 16
        }
        var i = this
        var n = 15u16

        if (i >= 1 << 8) {
            n -= 8
            i >>= 8
        }
        if (i >= 1 << 4) {
            n -= 4
            i >>= 4
        }
        if (i >= 1 << 2) {
            n -= 2
            i >>= 2
        }
        return n - (i >> 1)
    }
    public prop isEven: Bool {
        get() {
            (this & 1) == 0
        }
    }
    public prop isOdd: Bool {
        get(){
            !isEven
        }
    }
    @OverflowWrapping
    public func toInt(): Int16 {
        Int16(this & 0x7fff) | Int16(this & (1 << 15))
    }
}
extend UInt32 <: UnsignedInteger<UInt32, Int32> {
    public static prop bytes: Int64 {
        get() {
            4
        }
    }
    public static prop zero: UInt32 {
        get() {
            0
        }
    }
    public static prop one: UInt32 {
        get() {
            1
        }
    }
    public static prop ten: UInt32 {
        get() {
            10
        }
    }
    public static prop max: UInt32 {
        get() {
            UInt32.Max
        }
    }
    public static prop min: UInt32 {
        get() {
            UInt32.Min
        }
    }
    public func numberOfLeadingZeros(): UInt32 {
        if (this == 0) {
            return 32
        }
        var i = this
        var n = 31u32

        if (i >= 1 << 16) {
            n -= 16
            i >>= 16
        }
        if (i >= 1 << 8) {
            n -= 8
            i >>= 8
        }
        if (i >= 1 << 4) {
            n -= 4
            i >>= 4
        }
        if (i >= 1 << 2) {
            n -= 2
            i >>= 2
        }
        return n - (i >> 1)
    }
    public prop isEven: Bool {
        get() {
            (this & 1) == 0
        }
    }
    public prop isOdd: Bool {
        get(){
            !isEven
        }
    }
    @OverflowWrapping
    public func toInt(): Int32 {
        Int32(this & 0x7fff_ffff) | Int32(this & (1 << 31))
    }
}
extend UInt64 <: UnsignedInteger<UInt64, Int64> {
    public static prop bytes: Int64 {
        get() {
            8
        }
    }
    public static prop zero: UInt64 {
        get() {
            0
        }
    }
    public static prop one: UInt64 {
        get() {
            1
        }
    }
    public static prop ten: UInt64 {
        get() {
            10
        }
    }
    public static prop max: UInt64 {
        get() {
            UInt64.Max
        }
    }
    public static prop min: UInt64 {
        get() {
            UInt64.Min
        }
    }
    public func numberOfLeadingZeros(): UInt64 {
        if (this == 0) {
            return 64
        }
        var i = this
        var n = 63u64

        if (i >= 1 << 32) {
            n -= 32
            i >>= 32
        }
        if (i >= 1 << 16) {
            n -= 16
            i >>= 16
        }
        if (i >= 1 << 8) {
            n -= 8
            i >>= 8
        }
        if (i >= 1 << 4) {
            n -= 4
            i >>= 4
        }
        if (i >= 1 << 2) {
            n -= 2
            i >>= 2
        }
        return n - (i >> 1)
    }
    
    public prop isEven: Bool {
        get() {
            (this & 1) == 0
        }
    }
    public prop isOdd: Bool {
        get(){
            !isEven
        }
    }
    @OverflowWrapping
    public func toInt(): Int64 {
        Int64(this & 0x7fff_ffff_ffff_ffff) | Int64(this & (1 << 63))
    }
}

extend Float16 <: Float<Float16> {
    public static prop bytes: Int64 {
        get() {
            2
        }
    }
    public static prop zero: Float16 {
        get() {
            0.0
        }
    }
    public static prop one: Float16 {
        get() {
            1.0
        }
    }
    public static prop ten: Float16 {
        get() {
            10.0
        }
    }
}

extend Float32 <: Float<Float32> {
    public static prop bytes: Int64 {
        get() {
            4
        }
    }
    public static prop zero: Float32 {
        get() {
            0.0
        }
    }
    public static prop one: Float32 {
        get() {
            1.0
        }
    }
    public static prop ten: Float32 {
        get() {
            10.0
        }
    }
}

extend Float64 <: Float<Float64> {
    public static prop bytes: Int64 {
        get() {
            8
        }
    }
    public static prop zero: Float64 {
        get() {
            0.0
        }
    }
    public static prop one: Float64 {
        get() {
            1.0
        }
    }
    public static prop ten: Float64 {
        get() {
            10.0
        }
    }
}

let zeroBigInt = BigInt(0)
let oneBigInt = BigInt(1)
let tenBigInt = BigInt(10)
let oneHundredBigInt = BigInt(100)

public interface ExtendBigInt {}

extend BigInt <: ExtendBigInt {
    public static prop zero: BigInt {
        get() {
            zeroBigInt
        }
    }
    public static prop one: BigInt {
        get() {
            oneBigInt
        }
    }
    public static prop ten: BigInt {
        get() {
            tenBigInt
        }
    }
    public static prop oneHundred: BigInt {
        get() {
            oneHundredBigInt
        }
    }
}

let zeroDecimal = Decimal(Float64.zero)
let oneDecimal = Decimal(Float64.one)
let tenDecimal = Decimal(Float64.ten)
let oneHundredDecimal = Decimal("100")
let piDecimal = Decimal(Float64.PI.toString())
let eDecimal = Decimal(Float64.E.toString())

public interface ExtendDecimal {}

extend Decimal <: ExtendDecimal {
    public static prop zero: Decimal {
        get() {
            zeroDecimal
        }
    }
    public static prop one: Decimal {
        get() {
            oneDecimal
        }
    }
    public static prop ten: Decimal {
        get() {
            tenDecimal
        }
    }
    public static prop oneHundred: Decimal {
        get() {
            oneHundredDecimal
        }
    }
    public static prop pi: Decimal {
        get() {
            piDecimal
        }
    }
    public static prop e: Decimal {
        get() {
            eDecimal
        }
    }
}

public interface Powerable<T, P> where T <: Powerable<T, P> {
    operator func **(right: P): T
}

extend Int64 <: Powerable<Int64, UInt64> {}

extend Float64 <: Powerable<Float64, Int64> {}

extend Float64 <: Powerable<Float64, Float64> {}

extend Decimal <: Powerable<Decimal, Int64> {}

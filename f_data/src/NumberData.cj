/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_data

import std.math.numeric.OverflowStrategy

extend Int8 <: DataFields<Int8> {
    public func toData(): Data {
        DataReal(this)
    }
    public static func fromData(data: Data, flag!: UInt64 = SILENCE): Int8 {
        tryFromData(data, flag: flag).getOrThrow {DataException("${data} cannot be converted to Int8")}
    }
    public static func tryFromData(data: Data, flag!: UInt64 = SILENCE): ?Int8 {
        match (data) {
            case x: DataReal where flag == SILENCE => x.tryToInt8()
            case x: DataReal where (flag & WRAPPING_ON_INT_OVERFLOW) != 0 => x.toInt8(strategy: wrapping)
            case x: DataReal where (flag & THROWING_ON_INT_OVERFLOW) != 0 => x.toInt8(strategy: throwing)
            case x: DataReal where (flag & SATURATING_ON_INT_OVERFLOW) != 0 => x.toInt8(strategy: saturating)
            case x: DataString where flag == SILENCE => DataReal(x.toString()).tryToInt8()
            case x: DataString where (flag & WRAPPING_ON_INT_OVERFLOW) != 0 => DataReal(x.toString()).toInt8(strategy: wrapping)
            case x: DataString where (flag & THROWING_ON_INT_OVERFLOW) != 0 => DataReal(x.toString()).toInt8(strategy: throwing)
            case x: DataString where (flag & SATURATING_ON_INT_OVERFLOW) != 0 => DataReal(x.toString()).toInt8(strategy: saturating)
            case _ => None<Int8>
        }
    }
}

extend UInt8 <: DataFields<UInt8> {
    public func toData(): Data {
        DataReal(this)
    }
    public static func fromData(data: Data, flag!: UInt64 = SILENCE): UInt8 {
        tryFromData(data, flag: flag).getOrThrow {DataException("${data} cannot be converted to UInt8")}
    }
    public static func tryFromData(data: Data, flag!: UInt64 = SILENCE): ?UInt8 {
        match (data) {
            case x: DataReal where flag == SILENCE => x.tryToUInt8()
            case x: DataReal where (flag & WRAPPING_ON_INT_OVERFLOW) != 0 => x.toUInt8(strategy: wrapping)
            case x: DataReal where (flag & THROWING_ON_INT_OVERFLOW) != 0 => x.toUInt8(strategy: throwing)
            case x: DataReal where (flag & SATURATING_ON_INT_OVERFLOW) != 0 => x.toUInt8(strategy: saturating)
            case x: DataString where flag == SILENCE => DataReal(x.toString()).tryToUInt8()
            case x: DataString where (flag & WRAPPING_ON_INT_OVERFLOW) != 0 => DataReal(x.toString()).toUInt8(strategy: wrapping)
            case x: DataString where (flag & THROWING_ON_INT_OVERFLOW) != 0 => DataReal(x.toString()).toUInt8(strategy: throwing)
            case x: DataString where (flag & SATURATING_ON_INT_OVERFLOW) != 0 => DataReal(x.toString()).toUInt8(strategy: saturating)
            case _ => None<UInt8>
        }
    }
}

extend Int16 <: DataFields<Int16> {
    public func toData(): Data {
        DataReal(this)
    }
    public static func fromData(data: Data, flag!: UInt64 = SILENCE): Int16 {
        tryFromData(data, flag: flag).getOrThrow {DataException("${data} cannot be converted to Int16")}
    }
    public static func tryFromData(data: Data, flag!: UInt64 = SILENCE): ?Int16 {
        match (data) {
            case x: DataReal where flag == SILENCE => x.tryToInt16()
            case x: DataReal where (flag & WRAPPING_ON_INT_OVERFLOW) != 0 => x.toInt16(strategy: wrapping)
            case x: DataReal where (flag & THROWING_ON_INT_OVERFLOW) != 0 => x.toInt16(strategy: throwing)
            case x: DataReal where (flag & SATURATING_ON_INT_OVERFLOW) != 0 => x.toInt16(strategy: saturating)
            case x: DataString where flag == SILENCE => DataReal(x.toString()).tryToInt16()
            case x: DataString where (flag & WRAPPING_ON_INT_OVERFLOW) != 0 => DataReal(x.toString()).toInt16(strategy: wrapping)
            case x: DataString where (flag & THROWING_ON_INT_OVERFLOW) != 0 => DataReal(x.toString()).toInt16(strategy: throwing)
            case x: DataString where (flag & SATURATING_ON_INT_OVERFLOW) != 0 => DataReal(x.toString()).toInt16(strategy: saturating)
            case _ => None<Int16>
        }
    }
}

extend UInt16 <: DataFields<UInt16> {
    public func toData(): Data {
        DataReal(this)
    }
    public static func fromData(data: Data, flag!: UInt64 = SILENCE): UInt16 {
        tryFromData(data, flag: flag).getOrThrow {DataException("${data} cannot be converted to UInt16")}
    }
    public static func tryFromData(data: Data, flag!: UInt64 = SILENCE): ?UInt16 {
        match (data) {
            case x: DataReal where flag == SILENCE => x.tryToUInt16()
            case x: DataReal where (flag & WRAPPING_ON_INT_OVERFLOW) != 0 => x.toUInt16(strategy: wrapping)
            case x: DataReal where (flag & THROWING_ON_INT_OVERFLOW) != 0 => x.toUInt16(strategy: throwing)
            case x: DataReal where (flag & SATURATING_ON_INT_OVERFLOW) != 0 => x.toUInt16(strategy: saturating)
            case x: DataString where flag == SILENCE => DataReal(x.toString()).tryToUInt16()
            case x: DataString where (flag & WRAPPING_ON_INT_OVERFLOW) != 0 => DataReal(x.toString()).toUInt16(strategy: wrapping)
            case x: DataString where (flag & THROWING_ON_INT_OVERFLOW) != 0 => DataReal(x.toString()).toUInt16(strategy: throwing)
            case x: DataString where (flag & SATURATING_ON_INT_OVERFLOW) != 0 => DataReal(x.toString()).toUInt16(strategy: saturating)
            case _ => None<UInt16>
        }
    }
}

extend Int32 <: DataFields<Int32> {
    public func toData(): Data {
        DataReal(this)
    }
    public static func fromData(data: Data, flag!: UInt64 = SILENCE): Int32 {
        tryFromData(data, flag: flag).getOrThrow {DataException("${data} cannot be converted to Int32")}
    }
    public static func tryFromData(data: Data, flag!: UInt64 = SILENCE): ?Int32 {
        match (data) {
            case x: DataReal where flag == SILENCE => x.tryToInt32()
            case x: DataReal where (flag & WRAPPING_ON_INT_OVERFLOW) != 0 => x.toInt32(strategy: wrapping)
            case x: DataReal where (flag & THROWING_ON_INT_OVERFLOW) != 0 => x.toInt32(strategy: throwing)
            case x: DataReal where (flag & SATURATING_ON_INT_OVERFLOW) != 0 => x.toInt32(strategy: saturating)
            case x: DataString where flag == SILENCE => DataReal(x.toString()).tryToInt32()
            case x: DataString where (flag & WRAPPING_ON_INT_OVERFLOW) != 0 => DataReal(x.toString()).toInt32(strategy: wrapping)
            case x: DataString where (flag & THROWING_ON_INT_OVERFLOW) != 0 => DataReal(x.toString()).toInt32(strategy: throwing)
            case x: DataString where (flag & SATURATING_ON_INT_OVERFLOW) != 0 => DataReal(x.toString()).toInt32(strategy: saturating)
            case _ => None<Int32>
        }
    }
}

extend UInt32 <: DataFields<UInt32> {
    public func toData(): Data {
        DataReal(this)
    }
    public static func fromData(data: Data, flag!: UInt64 = SILENCE): UInt32 {
        tryFromData(data, flag: flag).getOrThrow {DataException("${data} cannot be converted to UInt32")}
    }
    public static func tryFromData(data: Data, flag!: UInt64 = SILENCE): ?UInt32 {
        match (data) {
            case x: DataReal where flag == SILENCE => x.tryToUInt32()
            case x: DataReal where (flag & WRAPPING_ON_INT_OVERFLOW) != 0 => x.toUInt32(strategy: wrapping)
            case x: DataReal where (flag & THROWING_ON_INT_OVERFLOW) != 0 => x.toUInt32(strategy: throwing)
            case x: DataReal where (flag & SATURATING_ON_INT_OVERFLOW) != 0 => x.toUInt32(strategy: saturating)
            case x: DataString where flag == SILENCE => DataReal(x.toString()).tryToUInt32()
            case x: DataString where (flag & WRAPPING_ON_INT_OVERFLOW) != 0 => DataReal(x.toString()).toUInt32(strategy: wrapping)
            case x: DataString where (flag & THROWING_ON_INT_OVERFLOW) != 0 => DataReal(x.toString()).toUInt32(strategy: throwing)
            case x: DataString where (flag & SATURATING_ON_INT_OVERFLOW) != 0 => DataReal(x.toString()).toUInt32(strategy: saturating)
            case _ => None<UInt32>
        }
    }
}

extend Int64 <: DataFields<Int64> {
    public func toData(): Data {
        DataReal(this)
    }
    public static func fromData(data: Data, flag!: UInt64 = SILENCE): Int64 {
        tryFromData(data, flag: flag).getOrThrow {DataException("${data} cannot be converted to Int64")}
    }
    public static func tryFromData(data: Data, flag!: UInt64 = SILENCE): ?Int64 {
        match (data) {
            case x: DataReal where flag == SILENCE => x.tryToInt64()
            case x: DataReal where (flag & WRAPPING_ON_INT_OVERFLOW) != 0 => x.toInt64(strategy: wrapping)
            case x: DataReal where (flag & THROWING_ON_INT_OVERFLOW) != 0 => x.toInt64(strategy: throwing)
            case x: DataReal where (flag & SATURATING_ON_INT_OVERFLOW) != 0 => x.toInt64(strategy: saturating)
            case x: DataString where flag == SILENCE => DataReal(x.toString()).tryToInt64()
            case x: DataString where (flag & WRAPPING_ON_INT_OVERFLOW) != 0 => DataReal(x.toString()).toInt64(strategy: wrapping)
            case x: DataString where (flag & THROWING_ON_INT_OVERFLOW) != 0 => DataReal(x.toString()).toInt64(strategy: throwing)
            case x: DataString where (flag & SATURATING_ON_INT_OVERFLOW) != 0 => DataReal(x.toString()).toInt64(strategy: saturating)
            case _ => None<Int64>
        }
    }
}

extend UInt64 <: DataFields<UInt64> {
    public func toData(): Data {
        DataReal(this)
    }
    public static func fromData(data: Data, flag!: UInt64 = SILENCE): UInt64 {
        tryFromData(data, flag: flag).getOrThrow {DataException("${data} cannot be converted to UInt64")}
    }
    public static func tryFromData(data: Data, flag!: UInt64 = SILENCE): ?UInt64 {
        match (data) {
            case x: DataReal where flag == SILENCE => x.tryToUInt64()
            case x: DataReal where (flag & WRAPPING_ON_INT_OVERFLOW) != 0 => x.toUInt64(strategy: wrapping)
            case x: DataReal where (flag & THROWING_ON_INT_OVERFLOW) != 0 => x.toUInt64(strategy: throwing)
            case x: DataReal where (flag & SATURATING_ON_INT_OVERFLOW) != 0 => x.toUInt64(strategy: saturating)
            case x: DataString where flag == SILENCE => DataReal(x.toString()).tryToUInt64()
            case x: DataString where (flag & WRAPPING_ON_INT_OVERFLOW) != 0 => DataReal(x.toString()).toUInt64(strategy: wrapping)
            case x: DataString where (flag & THROWING_ON_INT_OVERFLOW) != 0 => DataReal(x.toString()).toUInt64(strategy: throwing)
            case x: DataString where (flag & SATURATING_ON_INT_OVERFLOW) != 0 => DataReal(x.toString()).toUInt64(strategy: saturating)
            case _ => None<UInt64>
        }
    }
}

extend IntNative <: DataFields<IntNative> {
    public func toData(): Data {
        DataReal(this)
    }
    public static func fromData(data: Data, flag!: UInt64 = SILENCE): IntNative {
        tryFromData(data, flag: flag).getOrThrow {DataException("${data} cannot be converted to IntNative")}
    }
    public static func tryFromData(data: Data, flag!: UInt64 = SILENCE): ?IntNative {
        match (data) {
            case x: DataReal where flag == SILENCE => x.tryToIntNative()
            case x: DataReal where (flag & WRAPPING_ON_INT_OVERFLOW) != 0 => x.toIntNative(strategy: wrapping)
            case x: DataReal where (flag & THROWING_ON_INT_OVERFLOW) != 0 => x.toIntNative(strategy: throwing)
            case x: DataReal where (flag & SATURATING_ON_INT_OVERFLOW) != 0 => x.toIntNative(strategy: saturating)
            case x: DataString where flag == SILENCE => DataReal(x.toString()).tryToIntNative()
            case x: DataString where (flag & WRAPPING_ON_INT_OVERFLOW) != 0 => DataReal(x.toString()).toIntNative(strategy: wrapping)
            case x: DataString where (flag & THROWING_ON_INT_OVERFLOW) != 0 => DataReal(x.toString()).toIntNative(strategy: throwing)
            case x: DataString where (flag & SATURATING_ON_INT_OVERFLOW) != 0 => DataReal(x.toString()).toIntNative(strategy: saturating)
            case _ => None<IntNative>
        }
    }
}

extend UIntNative <: DataFields<UIntNative> {
    public func toData(): Data {
        DataReal(this)
    }
    public static func fromData(data: Data, flag!: UInt64 = SILENCE): UIntNative {
        tryFromData(data, flag: flag).getOrThrow {DataException("${data} cannot be converted to UIntNative")}
    }
    public static func tryFromData(data: Data, flag!: UInt64 = SILENCE): ?UIntNative {
        match (data) {
            case x: DataReal where flag == SILENCE => x.tryToUIntNative()
            case x: DataReal where (flag & WRAPPING_ON_INT_OVERFLOW) != 0 => x.toUIntNative(strategy: wrapping)
            case x: DataReal where (flag & THROWING_ON_INT_OVERFLOW) != 0 => x.toUIntNative(strategy: throwing)
            case x: DataReal where (flag & SATURATING_ON_INT_OVERFLOW) != 0 => x.toUIntNative(strategy: saturating)
            case x: DataString where flag == SILENCE => DataReal(x.toString()).tryToUIntNative()
            case x: DataString where (flag & WRAPPING_ON_INT_OVERFLOW) != 0 => DataReal(x.toString()).toUIntNative(strategy: wrapping)
            case x: DataString where (flag & THROWING_ON_INT_OVERFLOW) != 0 => DataReal(x.toString()).toUIntNative(strategy: throwing)
            case x: DataString where (flag & SATURATING_ON_INT_OVERFLOW) != 0 => DataReal(x.toString()).toUIntNative(strategy: saturating)
            case _ => None<UIntNative>
        }
    }
}

extend Float64 <: DataFields<Float64> {
    public func toData(): Data {
        DataReal(this)
    }
    public static func fromData(data: Data, flag!: UInt64 = SILENCE): Float64 {
        tryFromData(data, flag: flag).getOrThrow {DataException("${data} cannot be converted to Float64")}
    }
    public static func tryFromData(data: Data, flag!: UInt64 = SILENCE): ?Float64 {
        match (data) {
            case x: DataReal => x.tryToFloat64()
            case x: DataString => DataReal(x.toString()).tryToFloat64()
            case _ => None<Float64>
        }
    }
}

extend Float32 <: DataFields<Float32> {
    public func toData(): Data {
        DataReal(this)
    }
    public static func fromData(data: Data, flag!: UInt64 = SILENCE): Float32 {
        tryFromData(data, flag: flag).getOrThrow {DataException("${data} cannot be converted to Float32")}
    }
    public static func tryFromData(data: Data, flag!: UInt64 = SILENCE): ?Float32 {
        match (data) {
            case x: DataReal => x.tryToFloat32()
            case x: DataString => DataReal(x.toString()).tryToFloat32()
            case _ => None<Float32>
        }
    }
}

extend Float16 <: DataFields<Float16> {
    public func toData(): Data {
        DataReal(this)
    }
    public static func fromData(data: Data, flag!: UInt64 = SILENCE): Float16 {
        tryFromData(data, flag: flag).getOrThrow {DataException("${data} cannot be converted to Float16")}
    }
    public static func tryFromData(data: Data, flag!: UInt64 = SILENCE): ?Float16 {
        match (data) {
            case x: DataReal => x.tryToFloat16()
            case x: DataString => DataReal(x.toString()).tryToFloat16()
            case _ => None<Float16>
        }
    }
}

extend BigInt <: DataFields<BigInt> {
    public func toData(): Data {
        DataReal(this)
    }
    public static func fromData(data: Data, flag!: UInt64 = SILENCE): BigInt {
        tryFromData(data, flag: flag).getOrThrow {DataException("${data} cannot be converted to BigInt")}
    }
    public static func tryFromData(data: Data, flag!: UInt64 = SILENCE): ?BigInt {
        match (data) {
            case x: DataReal => x.tryToBigInt()
            case x: DataString => DataReal(x.toString()).tryToBigInt()
            case _ => None<BigInt>
        }
    }
}

extend Decimal <: DataFields<Decimal> {
    public func toData(): Data {
        DataReal(this)
    }
    public static func fromData(data: Data, flag!: UInt64 = SILENCE): Decimal {
        tryFromData(data, flag: flag).getOrThrow {DataException("${data} cannot be converted to Decimal")}
    }
    public static func tryFromData(data: Data, flag!: UInt64 = SILENCE): ?Decimal {
        match (data) {
            case x: DataReal => x.tryToDecimal()
            case x: DataString => DataReal(x.toString()).tryToDecimal()
            case _ => None<Decimal>
        }
    }
}

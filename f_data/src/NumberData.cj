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

extend Int8 <: DataFields<Int8> {
    public func toData(): Data {
        DataReal(this)
    }
    public static func fromData(data: Data): Int8 {
        tryFromData(data).getOrThrow{DataException("${data} cannot be converted to Int8")}
    }
    public static func tryFromData(data: Data): ?Int8 {
        match(data){
            case x: DataReal => x.tryToInt8()
            case x: DataString => DataReal(x.toString()).tryToInt8()
            case _ => None<Int8>
        }
    }
}
extend UInt8 <: DataFields<UInt8> {
    public func toData(): Data {
        DataReal(this)
    }
    public static func fromData(data: Data): UInt8 {
        tryFromData(data).getOrThrow{DataException("${data} cannot be converted to UInt8")}
    }
    public static func tryFromData(data: Data): ?UInt8 {
        match(data){
            case x: DataReal => x.tryToUInt8()
            case x: DataString => DataReal(x.toString()).tryToUInt8()
            case _ => None<UInt8>
        }
    }
}
extend Int16 <: DataFields<Int16> {
    public func toData(): Data {
        DataReal(this)
    }
    public static func fromData(data: Data): Int16 {
        tryFromData(data).getOrThrow{DataException("${data} cannot be converted to Int16")}
    }
    public static func tryFromData(data: Data): ?Int16 {
        match(data){
            case x: DataReal => x.tryToInt16()
            case x: DataString => DataReal(x.toString()).tryToInt16()
            case _ => None<Int16>
        }
    }
}
extend UInt16 <: DataFields<UInt16> {
    public func toData(): Data {
        DataReal(this)
    }
    public static func fromData(data: Data): UInt16 {
        tryFromData(data).getOrThrow{DataException("${data} cannot be converted to UInt16")}
    }
    public static func tryFromData(data: Data): ?UInt16 {
        match(data){
            case x: DataReal => x.tryToUInt16()
            case x: DataString => DataReal(x.toString()).tryToUInt16()
            case _ => None<UInt16>
        }
    }
}
extend Int32 <: DataFields<Int32> {
    public func toData(): Data {
        DataReal(this)
    }
    public static func fromData(data: Data): Int32 {
        tryFromData(data).getOrThrow{DataException("${data} cannot be converted to Int32")}
    }
    public static func tryFromData(data: Data): ?Int32 {
        match(data){
            case x: DataReal => x.tryToInt32()
            case x: DataString => DataReal(x.toString()).tryToInt32()
            case _ => None<Int32>
        }
    }
}
extend UInt32 <: DataFields<UInt32> {
    public func toData(): Data {
        DataReal(this)
    }
    public static func fromData(data: Data): UInt32 {
        tryFromData(data).getOrThrow{DataException("${data} cannot be converted to UInt32")}
    }
    public static func tryFromData(data: Data): ?UInt32 {
        match(data){
            case x: DataReal => x.tryToUInt32()
            case x: DataString => DataReal(x.toString()).tryToUInt32()
            case _ => None<UInt32>
        }
    }
}
extend Int64 <: DataFields<Int64> {
    public func toData(): Data {
        DataReal(this)
    }
    public static func fromData(data: Data): Int64 {
        tryFromData(data).getOrThrow{DataException("${data} cannot be converted to Int64")}
    }
    public static func tryFromData(data: Data): ?Int64 {
        match(data){
            case x: DataReal => x.tryToInt64()
            case x: DataString => DataReal(x.toString()).tryToInt64()
            case _ => None<Int64>
        }
    }
}
extend UInt64 <: DataFields<UInt64> {
    public func toData(): Data {
        DataReal(this)
    }
    public static func fromData(data: Data): UInt64 {
        tryFromData(data).getOrThrow{DataException("${data} cannot be converted to UInt64")}
    }
    public static func tryFromData(data: Data): ?UInt64 {
        match(data){
            case x: DataReal => x.tryToUInt64()
            case x: DataString => DataReal(x.toString()).tryToUInt64()
            case _ => None<UInt64>
        }
    }
}

extend IntNative <: DataFields<IntNative> {
    public func toData(): Data {
        DataReal(this)
    }
    public static func fromData(data: Data): IntNative {
        tryFromData(data).getOrThrow{DataException("${data} cannot be converted to IntNative")}
    }
    public static func tryFromData(data: Data): ?IntNative {
        match(data){
            case x: DataReal => x.tryToIntNative()
            case x: DataString => DataReal(x.toString()).tryToIntNative()
            case _ => None<IntNative>
        }
    }
}
extend UIntNative <: DataFields<UIntNative> {
    public func toData(): Data {
        DataReal(this)
    }
    public static func fromData(data: Data): UIntNative {
        tryFromData(data).getOrThrow{DataException("${data} cannot be converted to UIntNative")}
    }
    public static func tryFromData(data: Data): ?UIntNative {
        match(data){
            case x: DataReal => x.tryToUIntNative()
            case x: DataString => DataReal(x.toString()).tryToUIntNative()
            case _ => None<UIntNative>
        }
    }
}
extend Float64 <: DataFields<Float64> {
    public func toData(): Data {
        DataReal(this)
    }
    public static func fromData(data: Data): Float64 {
        tryFromData(data).getOrThrow{DataException("${data} cannot be converted to Float64")}
    }
    public static func tryFromData(data: Data): ?Float64 {
        match(data){
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
    public static func fromData(data: Data): Float32 {
        tryFromData(data).getOrThrow{DataException("${data} cannot be converted to Float32")}
    }
    public static func tryFromData(data: Data): ?Float32 {
        match(data){
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
    public static func fromData(data: Data): Float16 {
        tryFromData(data).getOrThrow{DataException("${data} cannot be converted to Float16")}
    }
    public static func tryFromData(data: Data): ?Float16 {
        match(data){
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
    public static func fromData(data: Data): BigInt {
        tryFromData(data).getOrThrow{DataException("${data} cannot be converted to BigInt")}
    }
    public static func tryFromData(data: Data): ?BigInt {
        match(data){
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
    public static func fromData(data: Data): Decimal {
        tryFromData(data).getOrThrow{DataException("${data} cannot be converted to Decimal")}
    }
    public static func tryFromData(data: Data): ?Decimal {
        match(data){
            case x: DataReal => x.tryToDecimal()
            case x: DataString => DataReal(x.toString()).tryToDecimal()
            case _ => None<Decimal>
        }
    }
}

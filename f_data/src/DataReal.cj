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

import f_regex.*

public class DataReal <: Data & Hashable & Comparable<DataReal> {
    public DataReal(public let data: Decimal){}
    public init(data: BigInt){
        this(Decimal(data.toString()))
    }
    public init(data: Int8){
        this(Decimal(data))
    }
    public init(data: UInt8){
        this(Decimal(data))
    }
    public init(data: Int16){
        this(Decimal(data))
    }
    public init(data: UInt16){
        this(Decimal(data))
    }
    public init(data: Int32){
        this(Decimal(data))
    }
    public init(data: UInt32){
        this(Decimal(data))
    }
    public init(data: Int64){
        this(Decimal(data))
    }
    public init(data: UInt64){
        this(Decimal(data))
    }
    public init(data: IntNative){
        this(Decimal(data))
    }
    public init(data: UIntNative){
        this(Decimal(data))
    }
    public init(data: Float16){
        this(Decimal(data))
    }
    public init(data: Float32){
        this(Decimal(data))
    }
    public init(data: Float64){
        this(Decimal(data))
    }
    public init(data: String){
        this(Decimal(data))
    }

    public func toDecimal(){
        data
    }
    public func tryToDecimal(): ?Decimal {
        toDecimal()
    }
    public func toBigInt(){
        data.toBigInt()
    }
    public func tryToBigInt(): ?BigInt {
        data.toBigInt()
    }
    public func toFloat64(){
        data.toFloat64()
    }
    public func tryToFloat64(): ?Float64 {
        data.toFloat64()
    }
    public func toFloat32(){
        data.toFloat32()
    }
    public func tryToFloat32(): ?Float32 {
        data.toFloat32()
    }
    public func toFloat16(){
        data.toFloat16()
    }
    public func tryToFloat16(): ?Float16 {
        data.toFloat16()
    }
    private static let int8Range = [Decimal(Int8.Min), Decimal(Int8.Max)]
    private static let uint8Range = [Decimal(UInt8.Min), Decimal(UInt8.Max)]
    private static let int16Range = [Decimal(Int16.Min), Decimal(Int16.Max)]
    private static let uint16Range = [Decimal(UInt16.Min), Decimal(UInt16.Max)]
    private static let int32Range = [Decimal(Int32.Min), Decimal(Int32.Max)]
    private static let uint32Range = [Decimal(UInt32.Min), Decimal(UInt32.Max)]
    private static let int64Range = [Decimal(Int64.Min), Decimal(Int64.Max)]
    private static let uint64Range = [Decimal(UInt64.Min), Decimal(UInt64.Max)]
    public func toInt8(): Int8 {
        data.toInt8()
    }
    public func tryToInt8(): ?Int8 {
        if(data >= int8Range[0] && data <= int8Range[1]){
            data.toInt8()
        }else{
            None<Int8>
        }
    }
    public func toUInt8(): UInt8 {
        data.toUInt8()
    }
    public func tryToUInt8(): ?UInt8 {
        if(data >= uint8Range[0] && data <= uint8Range[1]){
            data.toUInt8()
        }else{
            None<UInt8>
        }
    }

    public func toInt16(): Int16 {
        data.toInt16()
    }
    public func tryToInt16(): ?Int16 {
        if(data >= int16Range[0] && data <= int16Range[1]){
            data.toInt16()
        }else{
            None<Int16>
        }
    }
    public func toUInt16(): UInt16 {
        data.toUInt16()
    }
    public func tryToUInt16(): ?UInt16 {
        if(data >= uint16Range[0] && data <= uint16Range[1]){
            data.toUInt16()
        }else{
            None<UInt16>
        }
    }

    public func toInt32(): Int32 {
        data.toInt32()
    }
    public func tryToInt32(): ?Int32 {
        if(data >= int32Range[0] && data <= int32Range[1]){
            data.toInt32()
        }else{
            None<Int32>
        }
    }
    public func toUInt32(): UInt32 {
        data.toUInt32()
    }
    public func tryToUInt32(): ?UInt32 {
        if(data >= uint32Range[0] && data <= uint32Range[1]){
            data.toUInt32()
        }else{
            None<UInt32>
        }
    }

    public func toInt64(): Int64 {
        data.toInt64()
    }
    public func tryToInt64(): ?Int64 {
        if(data >= int64Range[0] && data <= int64Range[1]){
            data.toInt64()
        }else{
            None<Int64>
        }
    }
    public func toUInt64(): UInt64 {
        data.toUInt64()
    }
    public func tryToUInt64(): ?UInt64 {
        if(data >= uint64Range[0] && data <= uint64Range[1]){
            data.toUInt64()
        }else{
            None<UInt64>
        }
    }
    public func toIntNative(): IntNative {
        data.toIntNative()
    }
    public func tryToIntNative(): ?IntNative {
        if(data >= int64Range[0] && data <= int64Range[1]){
            data.toIntNative()
        }else{
            None<IntNative>
        }
    }
    public func toUIntNative(): UIntNative {
        data.toUIntNative()
    }
    public func tryToUIntNative(): ?UIntNative {
        if(data >= int64Range[0] && data <= int64Range[1]){
            data.toUIntNative()
        }else{
            None<UIntNative>
        }
    }

    public func toString(): String {
        this.data.toString()
    }
    public static func parse(data: String): Data {
        DataReal(data)
    }
    public static func tryParse(data: String): ?Data {
        if (Regex.REAL_NUMBER.matched(data)) {
            parse(data)
        } else {
            None<Data>
        }
    }
    public func hashCode(): Int64 {
        data.hashCode()
    }
    public func compare(other: DataReal): Ordering {
        data.compare(other.data)
    }
}

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

public import std.math.numeric.{BigInt, Decimal, OverflowStrategy}
public import std.time.DateTime
public import std.collection.{ArrayList, HashSet, HashMap, TreeMap}
internal import std.convert.Parsable
import encoding.base64.toBase64String
import f_base.*
import f_exception.UnreachableException
import f_regex.{Regex, ExtendRegex}

public abstract class DataModel {
    
}
public class RealModel <: DataModel & ToString {
    public RealModel(public let value: Decimal){}
    public init(data: BigInt){
        this(Decimal(data))
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
    public init(data: IntNative){
        this(Decimal(data))
    }
    public init(data: UIntNative){
        this(Decimal(data))
    }
    public func toDecimal(){
        value
    }
    public func toBigInt(){
        value.toBigInt()
    }
    public func toFloat16(){
        value.toFloat16()
    }
    public func toFloat32(){
        value.toFloat32()
    }
    public func toFloat64(){
        value.toFloat64()
    }
    public func toInt64(overflowHandling!: OverflowStrategy = OverflowStrategy.throwing){
        value.toInt64(overflowHandling: overflowHandling)
    }
    public func toUInt64(overflowHandling!: OverflowStrategy = OverflowStrategy.throwing){
        value.toUInt64(overflowHandling: overflowHandling)
    }
    public func toInt32(overflowHandling!: OverflowStrategy = OverflowStrategy.throwing){
        value.toInt32(overflowHandling: overflowHandling)
    }
    public func toUInt32(overflowHandling!: OverflowStrategy = OverflowStrategy.throwing){
        value.toUInt32(overflowHandling: overflowHandling)
    }
    public func toInt16(overflowHandling!: OverflowStrategy = OverflowStrategy.throwing){
        value.toInt16(overflowHandling: overflowHandling)
    }
    public func toUInt16(overflowHandling!: OverflowStrategy = OverflowStrategy.throwing){
        value.toUInt16(overflowHandling: overflowHandling)
    }
    public func toInt8(overflowHandling!: OverflowStrategy = OverflowStrategy.throwing){
        value.toInt8(overflowHandling: overflowHandling)
    }
    public func toUInt8(overflowHandling!: OverflowStrategy = OverflowStrategy.throwing){
        value.toUInt8(overflowHandling: overflowHandling)
    }
    public func toIntNative(overflowHandling!: OverflowStrategy = OverflowStrategy.throwing){
        value.toIntNative(overflowHandling: overflowHandling)
    }
    public func toUIntNative(overflowHandling!: OverflowStrategy = OverflowStrategy.throwing){
        value.toUIntNative(overflowHandling: overflowHandling)
    }
    public func toString(): String {
        value.toString()
    }
}
public class BoolModel <: DataModel & ToString {
    public static let TRUE = BoolModel(true)
    public static let FALSE = BoolModel(false)
    public static func valueOf(v: Bool): BoolModel {
        if(v){
            TRUE
        }else{
            FALSE
        }
    }
    private BoolModel(public let value: Bool){}
    public func toString(){
        value.toString()
    }
}
public class RuneModel <: DataModel & ToString{
    public RuneModel(public let value: Rune){}
    public func toString(){
        value.toString()
    }
}
public class StringModel <: DataModel & ToString {
    public StringModel(public let value: String){}
    public func toString(){
        value.toString()
    }
    private static let INT_REGEX = Regex.INTEGER
    private static let REAL_NUM_REGEX = Regex.REAL_NUMBER
    public func toInt8(toThrowIfNotMatch!: Bool = false, overflowHandling!: OverflowStrategy = OverflowStrategy.throwing): ?Int8 {
        if(toThrowIfNotMatch || INT_REGEX.matched(value)){
            Decimal(value).toInt8(overflowHandling: overflowHandling)
        }else{
            throw IllegalArgumentException('${value} is not Int8')
        }
    }
    public func toUInt8(toThrowIfNotMatch!: Bool = false, overflowHandling!: OverflowStrategy = OverflowStrategy.throwing): ?UInt8 {
        if(toThrowIfNotMatch || INT_REGEX.matched(value)){
            Decimal(value).toUInt8(overflowHandling: overflowHandling)
        }else{
            throw IllegalArgumentException('${value} is not UInt8')
        }
    }
    public func toInt16(toThrowIfNotMatch!: Bool = false, overflowHandling!: OverflowStrategy = OverflowStrategy.throwing): ?Int16 {
        if(toThrowIfNotMatch || INT_REGEX.matched(value)){
            Decimal(value).toInt16(overflowHandling: overflowHandling)
        }else{
            throw IllegalArgumentException('${value} is not Int16')
        }
    }
    public func toUInt16(toThrowIfNotMatch!: Bool = false, overflowHandling!: OverflowStrategy = OverflowStrategy.throwing): ?UInt16 {
        if(toThrowIfNotMatch || INT_REGEX.matched(value)){
            Decimal(value).toUInt16(overflowHandling: overflowHandling)
        }else{
            throw IllegalArgumentException('${value} is not UInt16')
        }
    }
    public func toInt32(toThrowIfNotMatch!: Bool = false, overflowHandling!: OverflowStrategy = OverflowStrategy.throwing): ?Int32 {
        if(toThrowIfNotMatch || INT_REGEX.matched(value)){
            Decimal(value).toInt32(overflowHandling: overflowHandling)
        }else{
            throw IllegalArgumentException('${value} is not Int32')
        }
    }
    public func toUInt32(toThrowIfNotMatch!: Bool = false, overflowHandling!: OverflowStrategy = OverflowStrategy.throwing): ?UInt32 {
        if(toThrowIfNotMatch || INT_REGEX.matched(value)){
            Decimal(value).toUInt32(overflowHandling: overflowHandling)
        }else{
            throw IllegalArgumentException('${value} is not UInt32')
        }
    }
    public func toInt64(toThrowIfNotMatch!: Bool = false, overflowHandling!: OverflowStrategy = OverflowStrategy.throwing): ?Int64 {
        if(toThrowIfNotMatch || INT_REGEX.matched(value)){
            Decimal(value).toInt64(overflowHandling: overflowHandling)
        }else{
            throw IllegalArgumentException('${value} is not Int64')
        }
    }
    public func toUInt64(toThrowIfNotMatch!: Bool = false, overflowHandling!: OverflowStrategy = OverflowStrategy.throwing): ?UInt64 {
        if(toThrowIfNotMatch || INT_REGEX.matched(value)){
            Decimal(value).toUInt64(overflowHandling: overflowHandling)
        }else{
            throw IllegalArgumentException('${value} is not UInt64')
        }
    }
    public func toIntNative(toThrowIfNotMatch!: Bool = false, overflowHandling!: OverflowStrategy = OverflowStrategy.throwing): ?IntNative {
        if(toThrowIfNotMatch || INT_REGEX.matched(value)){
            Decimal(value).toIntNative(overflowHandling: overflowHandling)
        }else{
            throw IllegalArgumentException('${value} is not IntNative')
        }
    }
    public func toUIntNative(toThrowIfNotMatch!: Bool = false, overflowHandling!: OverflowStrategy = OverflowStrategy.throwing): ?UIntNative {
        if(toThrowIfNotMatch || INT_REGEX.matched(value)){
            Decimal(value).toUIntNative(overflowHandling: overflowHandling)
        }else{
            throw IllegalArgumentException('${value} is not UIntNative')
        }
    }
    public func toDecimal(toThrowIfNotMatch!: Bool = false): ?Decimal {
        if(toThrowIfNotMatch || REAL_NUM_REGEX.matched(value)){
            Decimal(value)
        }else{
            throw IllegalArgumentException('${value} is not real number')
        }
    }
    public func toBigInt(toThrowIfNotMatch!: Bool = false): ?BigInt {
         if(toThrowIfNotMatch || INT_REGEX.matched(value)){
            BigInt(value)
        }else{
            throw IllegalArgumentException('${value} is not integer')
        }
    }
    public func toFloat16(toThrowIfNotMatch!: Bool = false): ?Float16 {
        if(toThrowIfNotMatch || REAL_NUM_REGEX.matched(value)){
            Decimal(value).toFloat16()
        }else{
            throw IllegalArgumentException('${value} is not real number')
        }
    }
    public func toFloat32(toThrowIfNotMatch!: Bool = false): ?Float32 {
        if(toThrowIfNotMatch || REAL_NUM_REGEX.matched(value)){
            Decimal(value).toFloat32()
        }else{
            throw IllegalArgumentException('${value} is not real number')
        }
    }
    public func toFloat64(toThrowIfNotMatch!: Bool = false): ?Float64 {
        if(toThrowIfNotMatch || REAL_NUM_REGEX.matched(value)){
            Decimal(value).toFloat64()
        }else{
            throw IllegalArgumentException('${value} is not real number')
        }
    }
    private static let DURATION_REGEX = Regex.DURATION
    public func toDuration(toThrowIfNotMatch!: Bool = false): ?Duration{
        if(toThrowIfNotMatch || REAL_NUM_REGEX.matched(value)){
            Duration.parse(value)
        }else{
            throw IllegalArgumentException('${value} is not duration string')
        }
    }
    public func toDateTime(toThrowIfNotMatch!: Bool = false): ?DateTime{
        try{
            DateTime.parse(value)
        }catch(e: Exception){
            if(toThrowIfNotMatch){
                throw e
            }else{
                None
            }
        }
    }
    public func toDateTime(format: String, toThrowIfNotMatch!: Bool = false): ?DateTime{
        try{
            DateTime.parse(value, format)
        }catch(e: Exception){
            if(toThrowIfNotMatch){
                throw e
            }else{
                None
            }
        }
    }
    public func toDateTime(format: DateTimeFormat, toThrowIfNotMatch!: Bool = false): ?DateTime {
        try{
            DateTime.parse(value, format)
        }catch(e: Exception){
            if(toThrowIfNotMatch){
                throw e
            }else{
                None
            }
        }
    }
}
public class IntNativeModel <: DataModel & ToString {
    public IntNativeModel(public let value: IntNative){}
    public func toString(){
        value.toString()
    }
}
public class UIntNativeModel <: DataModel & ToString {
    public UIntNativeModel(public let value: UIntNative){}
    public func toString(){
        value.toString()
    }
}
public class DateTimeModel <: DataModel & ToString {
    public DateTimeModel(public let value: DateTime){}
    public func toString(){
        value.toString()
    }
    public func toDuration(): Duration{
        value - DateTime.UnixEpoch
    }
}
public class DurationModel <: DataModel & ToString {
    public DurationModel(public let value: Duration){}
    public func toString(){
        value.toString()
    }
    public func toDateTime(): DateTime {
        DateTime.UnixEpoch + value
    }
}
public class ByteArrayModel <: DataModel & ToString {
    public ByteArrayModel(public let value: Array<Byte>){}
    public func toString(){
        toBase64String(value)
    }
}
public class SequenceModel <: DataModel & Iterable<DataModel> {
    private let list = ArrayList<DataModel>()
    public init(){}
    public func append(model: DataModel): Unit {
        list.append(model)
    }
    public func append<T>(data: T): Unit where T <: Data {
        append(data.toModel())
    }
    public func appendAll<T, D>(models: T): Unit where T <: Iterable<D>, D <: Data {
        for(v in models){
            append(v.toModel())
        }
    }
    public func iterator(): Iterator<DataModel>{
        list.iterator()
    }
}
public class TupleModel <: DataModel{
    private let tuple: Array<DataModel>
    public init(first: DataModel, second: DataModel){
        tuple = [first, second]
    }
    public static func create<A, B>(first: A, second: B): TupleModel where A <: Data, B <: Data {
        TupleModel(first.toModel(), second.toModel())
    }
    public prop value: (DataModel, DataModel){
        get(){
            (tuple[0], tuple[1])
        }
    }
}
public class StringKeyMapModel <: DataModel & Iterable<TupleModel>{
    private let map = HashMap<String, TupleModel>()
    public init(){}
    public func put<V>(key: String, value: V): Unit where V <: Data {
        map[key] = TupleModel(key.toModel(), value.toModel())
    }
    public func get(key: String){
        map.get(key)
    }
    public func iterator(): Iterator<TupleModel>{
        map.values().iterator()
    }
}
public class NoneModel <: DataModel {
    public static let INSTANCE = NoneModel()
    private init(){}
}
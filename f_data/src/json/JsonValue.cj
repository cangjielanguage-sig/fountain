/*
Copyright (c) 2026 WuJingrun（吴京润）

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
package fountain::f_data.json

import std.io.{InputStream, OutputStream, ByteBuffer}
import std.reflect.TypeInfo
public import std.collection.{ArrayList, HashMap, Map}
public import std.math.numeric.{BigInt, Decimal}

public sealed abstract class JsonValue <: ToString & JsonSerializable & JsonDeserializable<JsonValue> {
    public func asNull(): JsonNull{
        if(let x: JsonNull <- this){
            x
        }else{
            throw JsonException('current is ${TypeInfo.of(this)}')
        }
    }
    public func asInt(): JsonInt{
        if(let x: JsonInt <- this){
            x
        } else if (let x: JsonDecimal <- this) {
            JsonInt(x.toBigInt())
        } else {
            throw JsonException('current is ${TypeInfo.of(this)}')
        }
    }
    public func asDecimal(): JsonDecimal{
        if(let x: JsonDecimal <- this){
            x
        } else if (let x: JsonInt <- this) {
            JsonDecimal(x.value)
        } else{
            throw JsonException('current is ${TypeInfo.of(this)}')
        }
    }
    public func asBool(): JsonBool{
        if(let x: JsonBool <- this){
            x
        }else{
            throw JsonException('current is ${TypeInfo.of(this)}')
        }
    }
    public func asString(): JsonString{
        if(let x: JsonString <- this){
            x
        }else{
            throw JsonException('current is ${TypeInfo.of(this)}')
        }
    }
    public func asArray(): JsonArray{
        if(let x: JsonArray <- this){
            x
        }else{
            throw JsonException('current is ${TypeInfo.of(this)}')
        }
    }
    public func asObject(): JsonObject{
        if(let x: JsonObject <- this){
            x
        }else{
            throw JsonException('current is ${TypeInfo.of(this)}')
        }
    }
    public prop kind: JsonKind {
        get(){
            match(this){
                case _: JsonNull => JsonKind.JsonNull
                case _: JsonBool => JsonKind.JsonBool
                case _: JsonInt => JsonKind.JsonInt
                case _: JsonDecimal => JsonKind.JsonDecimal
                case _: JsonString => JsonKind.JsonString
                case _: JsonArray => JsonKind.JsonArray
                case _: JsonObject => JsonKind.JsonObject
                case _ => throw UnreadableException()
            }
        }
    }
    public func toJsonString(): String {
        toJsonString(true)
    }
    public func toJsonString(pretty: Bool): String{
        toJsonString(if(pretty){
            WriteConfig.pretty
        }else{
            WriteConfig.compact
        })
    }
    public func write(output: OutputStream): Unit {
        write(output, false)
    }
    public func write(output: OutputStream, pretty: Bool): Unit {
        write(output, if(pretty){
            WriteConfig.pretty
        }else{
            WriteConfig.compact
        })
    }
    public func toJsonString(config: WriteConfig): String {
        let buf = ByteBuffer()
        write(buf, config, flush: true)
        String.unsafeUtf8(buf.bytes())
    }
    public func write(output: OutputStream, config: WriteConfig, flush!: Bool = true): Unit{
        let writer = JsonWriter(output)
        writer.writeConfig = config
        toJson(writer, flush)
    }
    public func write(writer: JsonWriter, flush!: Bool = true): Unit {
        toJson(writer, flush)
    }
    public func toJson(writer: JsonWriter): Unit {
        toJson(writer, false)
    }
    public func toJson(writer: JsonWriter, flush: Bool): Unit {
        match(this){
            case x: JsonNull => writer.writeNullValue()
            case x: JsonInt => writer.writeValue<BigInt>(x.value)
            case x: JsonDecimal => writer.writeValue<Decimal>(x.value)
            case x: JsonBool => writer.writeValue<Bool>(x.value)
            case x: JsonString => writer.writeValue<String>(x.value)
            case x: JsonArray => 
                writer.startArray()
                for(v in x){
                    v.toJson(writer, false)
                }
                writer.endArray()
            case x: JsonObject => 
                writer.startObject()
                for((k, v) in x){
                    writer.writeName(k)
                    v.toJson(writer, false)
                }
                writer.endObject()
            case _ => throw JsonException("Unsupported JsonValue type: ${TypeInfo.of(this)}" )
        }
        if(flush){
            writer.flush()
        }
    }
    public func toString(): String {
        toJsonString(false)
    }
    public static func fromStr(str: String): JsonValue {
        fromBytes(str.unsafeBytes())
    }
    public static func fromBytes(bytes: Array<Byte>): JsonValue {
        fromInput(ByteBuffer(bytes))
    }
    public static func fromInput(input: InputStream): JsonValue {
        fromJson(JsonReader(input))
    }
    public static func fromJson(reader: JsonReader): JsonValue {
        if(let Some(token) <- reader.peek()){
            match(token){
                case JsonNull => 
                    reader.skip()
                    JsonNull.instance
                case JsonBool =>
                    JsonBool(reader.readValue<Bool>())
                case JsonNumber =>
                    JsonDecimal(reader.readValue<Decimal>())
                case JsonString =>
                    JsonString(reader.readValue<String>())
                case BeginArray =>
                    reader.startArray()
                    let array = JsonArray()
                    while(let Some(token) <- reader.peek()){
                        match(token) {
                            case EndArray => 
                                reader.endArray()
                                return array
                            case _ => array.add(fromJson(reader))
                        }
                    }
                    throw JsonException("Unexpected end of reader")
                case BeginObject =>
                    reader.startObject()
                    let object = JsonObject()
                    while(let Some(token) <- reader.peek()){
                        match(token){
                            case Name =>
                                let name = reader.readName()
                                let value = fromJson(reader)
                                object.add(name, value)
                            case EndObject => 
                                reader.endObject()
                                return object
                            case _ => throw JsonException("Expected name or end of object")
                        }
                    }
                    throw JsonException("Unexpected end of reader")
                case EndArray => throw JsonException("Unexpected token EndArray")
                case EndObject => throw JsonException("Unexpected token EndObject")
                case Name => throw JsonException("Unexpected token Name")
            }
        }else{
            JsonNull.instance
        }
    }
}

public class JsonNull <: JsonValue {
    public static let instance = JsonNull()
}
public class JsonInt <: JsonValue {
    public JsonInt(public let value: BigInt){}
    public init(value: UInt8){
        this(BigInt(value))
    }
    public init(value: UInt16){
        this(BigInt(value))
    }
    public init(value: UInt32){
        this(BigInt(value))
    }
    public init(value: UInt64){
        this(BigInt(value))
    }
    public init(value: Int8){
        this(BigInt(value))
    }
    public init(value: Int16){
        this(BigInt(value))
    }
    public init(value: Int32){
        this(BigInt(value))
    }
    public init(value: Int64){
        this(BigInt(value))
    }
    public init(value: String){
        this(BigInt.parse(value))
    }
    public func toInt8(): Int8 {
        value.toInt8()
    }
    public func toInt16(): Int16 {
        value.toInt16()
    }
    public func toInt32(): Int32 {
        value.toInt32()
    }
    public func toInt64(): Int64 {
        value.toInt64()
    }
    public func toUInt8(): UInt8 {
        value.toUInt8()
    }
    public func toUInt16(): UInt16 {
        value.toUInt16()
    }
    public func toUInt32(): UInt32 {
        value.toUInt32()
    }
    public func toUInt64(): UInt64 {
        value.toUInt64()
    }
    public func toBigInt(): BigInt {
        value
    }
    public func toDecimal(): Decimal {
        Decimal(value)
    }
}
public class JsonDecimal <: JsonValue {
    public JsonDecimal(public let value: Decimal){}
    public init(value: BigInt){
        this(Decimal(value))
    }
    public init(value: Float16){
        this(Decimal(value))
    }
    public init(value: Float32){
        this(Decimal(value))
    }
    public init(value: Float64){
        this(Decimal(value))
    }
    public init(value: Int8){
        this(Decimal(value))
    }
    public init(value: Int16){
        this(Decimal(value))
    }
    public init(value: Int32){
        this(Decimal(value))
    }
    public init(value: Int64){
        this(Decimal(value))
    }
    public init(value: UInt8){
        this(Decimal(value))
    }
    public init(value: UInt16){
        this(Decimal(value))
    }
    public init(value: UInt32){
        this(Decimal(value))
    }
    public init(value: UInt64){
        this(Decimal(value))
    }
    public init(value: String){
        this(Decimal.parse(value))
    }
    public func toDecimal(): Decimal {
        value
    }
    public func toFloat16(): Float16 {
        value.toFloat16()
    }
    public func toFloat32(): Float32 {
        value.toFloat32()
    }
    public func toFloat64(): Float64 {
        value.toFloat64()
    }
    public func toInt8(): Int8 {
        value.toInt8()
    }
    public func toInt16(): Int16 {
        value.toInt16()
    }
    public func toInt32(): Int32 {
        value.toInt32()
    }
    public func toInt64(): Int64 {
        value.toInt64()
    }
    public func toUInt8(): UInt8 {
        value.toUInt8()
    }
    public func toUInt16(): UInt16 {
        value.toUInt16()
    }
    public func toUInt32(): UInt32 {
        value.toUInt32()
    }
    public func toUInt64(): UInt64 {
        value.toUInt64()
    }
    public func toBigInt(): BigInt {
        value.toBigInt()
    }
}
public class JsonBool <: JsonValue {
    public JsonBool(public let value: Bool){}
}

public class JsonString <: JsonValue {
    public JsonString(public let value: String){}
}
public class JsonArray <: JsonValue & Collection<JsonValue> {
    public JsonArray(private let list!: ArrayList<JsonValue> = ArrayList<JsonValue>()){}
    
    public prop size: Int64 {
        get(){
            list.size
        }
    }
    public func iterator(): Iterator<JsonValue> {
        return list.iterator()
    }
    public func toArray(): Array<JsonValue> {
        return list.toArray()
    }
    public func isEmpty(): Bool {
        return list.isEmpty()
    }
    public func getItems(): ArrayList<JsonValue> {
        return list
    }
    public func getItem(index: Int64): JsonValue {
        list[index]
    }
    public operator func [](index: Int64): JsonValue {
        list[index]
    }
    public func setItem(index: Int64, value: JsonValue): Unit {
        list[index] = value
    }
    public operator func [](index: Int64, value!: JsonValue): Unit {
        list[index] = value
    }
    public func remove(index: Int64): Unit {
        list.remove(at: index)
    }
    public func removeIf(predicate: (JsonValue) -> Bool): Unit {
        list.removeIf(predicate)
    }
    public func add(value: JsonValue): Unit {
        list.add(value)
    }
    public func add(value: UInt8): Unit {
        add(JsonInt(value))
    }
    public func add(value: UInt16): Unit {
        add(JsonInt(value))
    }
    public func add(value: UInt32): Unit {
        add(JsonInt(value))
    }
    public func add(value: UInt64): Unit {
        add(JsonInt(value))
    }
    public func add(value: Int8): Unit {
        add(JsonInt(value))
    }
    public func add(value: Int16): Unit {
        add(JsonInt(value))
    }
    public func add(value: Int32): Unit {
        add(JsonInt(value))
    }
    public func add(value: Int64): Unit {
        add(JsonInt(value))
    }
    public func add(value: BigInt): Unit {
        add(JsonInt(value))
    }
    public func add(value: Float16): Unit {
        add(JsonDecimal(value))
    }
    public func add(value: Float32): Unit {
        add(JsonDecimal(value))
    }
    public func add(value: Float64): Unit {
        add(JsonDecimal(value))
    }
    public func add(value: Decimal): Unit {
        add(JsonDecimal(value))
    }
    public func add(value: String): Unit {
        add(JsonString(value))
    }
    public func add(value: Bool): Unit {
        add(JsonBool(value))
    }
    public func addNull(): Unit {
        add(JsonNull.instance)
    }
}
public class JsonObject <: JsonValue & Collection<(String, JsonValue)> {
    public JsonObject(private let map!: HashMap<String, JsonValue> = HashMap<String, JsonValue>()){}
    
    public prop size: Int64 {
        get(){
            map.size
        }
    }
    public func isEmpty(): Bool {
        map.isEmpty()
    }
    public func iterator(): Iterator<(String, JsonValue)> {
        map.iterator()
    }
    public func remove(name: String): ?JsonValue {
        map.remove(name)
    }
    public func removeIf(predicate: (String, JsonValue) -> Bool): Unit {
        map.removeIf(predicate)
    }
    public func getFields(): HashMap<String, JsonValue> {
        map
    }
    public func contains(name: String): Bool {
        return map.contains(name)
    }
    public func get(name: String): ?JsonValue {
        return map.get(name)
    }
    public operator func [](name: String): JsonValue {
        map[name]
    }
    public operator func [](name: String, value!: JsonValue): Unit {
        map[name] = value
    }
    public func add(name: String, value: JsonValue): Unit {
        map.add(name, value)
    }
    public func add(name: String, value: Bool): Unit {
        map.add(name, JsonBool(value))
    }
    public func add(name: String, value: String): Unit {
        map.add(name, JsonString(value))
    }
    public func addNull(name: String): Unit {
        map.add(name, JsonNull.instance)
    }
    public func add(name: String, value: Int8): Unit {
        map.add(name, JsonInt(value))
    }
    public func add(name: String, value: Int16): Unit {
        map.add(name, JsonInt(value))
    }
    public func add(name: String, value: Int32): Unit {
        map.add(name, JsonInt(value))
    }
    public func add(name: String, value: Int64): Unit {
        map.add(name, JsonInt(value))
    }
    public func add(name: String, value: UInt8): Unit {
        map.add(name, JsonInt(value))
    }
    public func add(name: String, value: UInt16): Unit {
        map.add(name, JsonInt(value))
    }
    public func add(name: String, value: UInt32): Unit {
        map.add(name, JsonInt(value))
    }
    public func add(name: String, value: UInt64): Unit {
        map.add(name, JsonInt(value))
    }
    public func add(name: String, value: BigInt): Unit {
        map.add(name, JsonInt(value))
    }
    public func add(name: String, value: Decimal): Unit {
        map.add(name, JsonDecimal(value))
    }
    public func add(name: String, value: Float16): Unit {
        map.add(name, JsonDecimal(value))
    }
    public func add(name: String, value: Float32): Unit {
        map.add(name, JsonDecimal(value))
    }
    public func add(name: String, value: Float64): Unit {
        map.add(name, JsonDecimal(value))
    }
}
public enum JsonKind <: Equatable<JsonKind>{
    | JsonNull
    | JsonBool
    | JsonString
    | JsonArray
    | JsonObject
    | JsonInt
    | JsonDecimal
    public operator func ==(other: JsonKind){
        match((this, other)){
            case (JsonNull, JsonNull) | 
                 (JsonBool, JsonBool) | 
                 (JsonString, JsonString) | 
                 (JsonArray, JsonArray) | 
                 (JsonObject, JsonObject) | 
                 (JsonInt, JsonInt) | 
                 (JsonDecimal, JsonDecimal) => true
            case _ => false
        }
    }
    public prop isNull: Bool {
        get(){
            this == JsonKind.JsonNull
        }
    }
    public prop isBool: Bool {
        get(){
            this == JsonKind.JsonBool
        }
    }
    public prop isString: Bool {
        get(){
            this == JsonKind.JsonString
        }
    }
    public prop isArray: Bool {
        get(){
            this == JsonKind.JsonArray
        }
    }
    public prop isObject: Bool {
        get(){
            this == JsonKind.JsonObject
        }
    }
    public prop isInt: Bool {
        get(){
            this == JsonKind.JsonInt
        }
    }
    public prop isDecimal: Bool {
        get(){
            this == JsonKind.JsonDecimal
        }
    }
}
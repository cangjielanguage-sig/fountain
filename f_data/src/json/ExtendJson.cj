/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_data.json

import std.io.{InputStream, StringReader, OutputStream, StringWriter, ByteBuffer}
import stdx.encoding.json.*
import f_data.exception.DataException
import charset4cj.charset.encoding.Charset
import charset4cj.charset.{Charsets, TextReader, TextWriter}
// import charset4cj.{Charset, Charsets, TextReader, TextWriter}

public interface ExtendJsonValue {
    static func fromInput(input: InputStream, charset!: Charset): JsonValue {
        fromReader(TextReader(input, charset: charset))
    }
    static func fromReader<I>(reader: StringReader<I>): JsonValue where I <: InputStream {
        let buffer = ByteBuffer()
        let writer = StringWriter(buffer)
        while (let Some(line) <- reader.readln()) {
            writer.writeln(line)
        }
        writer.flush()
        JsonValue.fromStr(String.fromUtf8(buffer.bytes()))
    }
    static func fromReader(reader: TextReader): JsonValue {
        let buffer = ByteBuffer()
        let writer = StringWriter(buffer)
        while (let Some(line) <- reader.readln()) {
            writer.writeln(line)
        }
        writer.flush()
        JsonValue.fromStr(String.fromUtf8(buffer.bytes()))
    }
    func toData(): Data
    static func tryFromData(data: Data, flag!: DataConversionFlag): Any
}

public let JSON_NULL = JsonNull()

extend JsonValue <: ExtendJsonValue {
    public func toData(): Data {
        match (this) {
            case x: JsonBool => x.getValue().toData()
            case x: JsonInt => x.getValue().toData()
            case x: JsonFloat => x.getValue().toData()
            case x: JsonNull => DataNone.INSTANCE
            case x: JsonString => x.getValue().toData()
            case x: JsonArray => DataJsonArray(x)
            case x: JsonObject => DataJsonObject(x)
            case _ => throw UnreachableException()
        }
    }
    public static func tryFromData(data: Data, flag!: DataConversionFlag = DEFAULT_DATA_FLAG): Any {
        func from(data: Data) {
            match (tryFromData(data, flag: flag)) {
                case x: JsonValue => x
                case x: ?JsonValue => match (x) {
                    case Some(x) => x
                    case _ => JSON_NULL
                }
                case x: ?JsonBool => match (x) {
                    case Some(x) => x
                    case _ => JSON_NULL
                }
                case x: ?JsonInt => match (x) {
                    case Some(x) => x
                    case _ => JSON_NULL
                }
                case x: ?JsonFloat => match (x) {
                    case Some(x) => x
                    case _ => JSON_NULL
                }
                case x: ?JsonString => match (x) {
                    case Some(x) => x
                    case _ => JSON_NULL
                }
                case x: ?JsonObject => match (x) {
                    case Some(x) => x
                    case _ => JSON_NULL
                }
                case x: ?JsonArray => match (x) {
                    case Some(x) => x
                    case _ => JSON_NULL
                }
                case _ => JSON_NULL
            }
        }
        match (data) {
            case x: DataJsonArray => x.json
            case x: DataJsonObject => x.json
            case x: DataNone => JsonNull()
            case x: DataBool => JsonBool(x.data)
            case x: DataReal => JsonFloat(x.data.toInt64())
            case x: DataString => JsonString(x.data)
            case x: DataDateTime => JsonString(x.data.toString())
            case x: DataDuration => JsonString(x.data.toString())
            case x: Iterable<Data> =>
                let arr = JsonArray()
                for (d in x) {
                    arr.add(from(d))
                }
                arr
            case x: Iterable<(String, Data)> =>
                let obj = JsonObject()
                for ((k, v) in x) {
                    obj.put(k, from(v))
                }
                obj
            case x: Iterable<(Data, Data)> =>
                let obj = JsonObject()
                for ((k, v) in x) {
                    let jk = from(k)
                    let jv = from(k)
                    obj.put(jk.toString(), jv)
                }
            case _ => throw DataException("can not convert data type to JsonValue")
        }
    }
}

public class DataJsonArrayIterator <: Iterator<Data> {
    public DataJsonArrayIterator(private let itr: Iterator<JsonValue>) {}
    public func next(): ?Data {
        itr.next()?.toData()
    }
}

public class DataJsonArray <: Data & Collection<Data> {
    public DataJsonArray(public let json: JsonArray) {}
    public prop size: Int64 {
        get() {
            json.size()
        }
    }
    public func isEmpty() {
        size == 0
    }
    public func iterator(): Iterator<Data> {
        DataJsonArrayIterator(json.getItems().iterator())
    }
    public func toString() {
        json.toString()
    }
    public static func tryParse(s: String): ?Data {
        JsonValue.fromStr(s).toData()
    }
    public static func parse(s: String): Data {
        tryParse(s).getOrThrow {DataParsableException('${s} cannot be parsed to ${TypeInfos.get<DataJsonArray>()}')}
    }
}

public class DataJsonObjectIterator <: Iterator<(String, Data)> {
    public DataJsonObjectIterator(private let itr: Iterator<(String, JsonValue)>) {}
    public func next(): ?(String, Data) {
        for ((k, v) in itr) {
            (k, v.toData())
        }
        None
    }
}

public class DataJsonObject <: Data & Collection<(String, Data)> {
    public DataJsonObject(public let json: JsonObject) {}
    public prop size: Int64 {
        get() {
            json.size()
        }
    }
    public func isEmpty() {
        size == 0
    }
    public func iterator(): Iterator<(String, Data)> {
        DataJsonObjectIterator(json.getFields().iterator())
    }
    public func toString() {
        json.toString()
    }
    public static func tryParse(s: String): ?Data {
        JsonValue.fromStr(s).toData()
    }
    public static func parse(s: String): Data {
        tryParse(s).getOrThrow {DataParsableException('${s} cannot be parsed to ${TypeInfos.get<DataJsonObject>()}')}
    }
}

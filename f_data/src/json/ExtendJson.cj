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
import encoding.json.*

import f_data.exception.DataException

import charset4cj.charset.encoding.Charset
import charset4cj.charset.{Charsets, TextReader, TextWriter}

public interface ExtendJsonValue {
    static func fromInput(input: InputStream, charset!: Charset): JsonValue{
        fromReader(TextReader(input, charset: charset))
    }
    static func fromReader<I>(reader: StringReader<I>): JsonValue where I <: InputStream {
        let buffer = ByteBuffer()
        let writer = StringWriter(buffer)
        while(let Some(line) <- reader.readln()){
            writer.writeln(line)
        }
        writer.flush()
        JsonValue.fromStr(String.fromUtf8(buffer.bytes()))
    }
    static func fromReader(reader: TextReader): JsonValue{
        let buffer = ByteBuffer()
        let writer = StringWriter(buffer)
        while(let Some(line) <- reader.readln()){
            writer.writeln(line)
        }
        writer.flush()
        JsonValue.fromStr(String.fromUtf8(buffer.bytes()))
    }
    func toData(): Data
}
extend JsonValue <: ExtendJsonValue {
    public func toData(): Data {
        match(this){
            case x: JsonBool => x.getValue().toData()
            case x: JsonInt => x.getValue().toData()
            case x: JsonFloat => x.getValue().toData()
            case x: JsonNull => DataNone.INSTANCE
            case x: JsonString => x.getValue().toData()
            case x: JsonArray => 
                let seq = DataSequence()
                for(v in x.getItems()){
                    seq.add(v.toData())
                }
                seq
            case x: JsonObject => 
                let map = StringKeyMapTuples()
                for(tpl in x.getFields()){
                    map.add(tpl[0], tpl[1].toData())
                }
                map
        }
    }
}
/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.  
*/
package f_log.output

import std.time.DateTime
import stdx.log.{LogWriter, LogValue}

import f_base.{printStackTrace, BaseException}

protected class LogWriterImpl <: LogWriter {
    public LogWriterImpl(private let writer: OutputStream){}
    public func writeNone(): Unit{
        writeString('None')
    }
    public func writeInt(v: Int64): Unit{
        writeString(v.toString())
    }
    public func writeUInt(v: UInt64): Unit{
        writeString(v.toString())
    }
    public func writeBool(v: Bool): Unit{
        writeString(v.toString())
    }
    public func writeFloat(v: Float64): Unit{
        writeString(v.toString())
    }
    public func writeString(v: String): Unit{
        writer.write(v.toArray())
    }
    public func writeDateTime(v: DateTime): Unit{
        writeString(v.toString())
    }
    public func writeDuration(v: Duration): Unit{
        writeString(v.toString())
    }
    public func writeKey(v: String): Unit{
        writeString(v)
    }
    public func writeValue(v: LogValue): Unit{
        v.writeTo(this)
    }
    public func startArray(): Unit{
        writeString('[')
    }
    public func endArray(): Unit{
        writeString(']')
    }
    public func startObject(): Unit{
        writeString('{')
    }
    public func endObject(): Unit{
        writeString('}')
    }
    public func writeException(v: Exception): Unit {
        if (let c: BaseException <- v) {
            c.printStackTrace(writer)
        } else {
            printStackTrace(v, writer)
        }
    }
}
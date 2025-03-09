/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_orm.wrap

import std.io.{InputStream, ByteArrayStream, StringReader, StringEncoding, Endian, CURRENT_ENDIAN}
import charset.charset.*
import charset.charset.encoding.*

public class DataInputStream <: InputStream & Data<DataInputStream> {
    public DataInputStream(private let input: InputStream) {}
    public static func new(bytes: Array<Byte>): DataInputStream {
        let input = ByteArrayStream(bytes.size)
        input.write(bytes)
        DataInputStream(input)
    }
    public func read(buffer: Array<Byte>): Int64 {
        input.read(buffer)
    }
    // public prop length: Int64 {
    //     get() {
    //         input.length
    //     }
    // }
    public func reader(encoding!: StringEncoding = UTF8, endian!: Endian = CURRENT_ENDIAN): StringReader<InputStream> {
        StringReader<InputStream>(input, encoding: encoding, endian: endian)
    }
    public func reader(charset!: Charset = Charsets.UTF8, bufSize!: Int64 = 8192): TextReader {
        TextReader(input, charset: charset, bufSize: bufSize)
    }

    public func getValue(): DataInputStream {
        this
    }
    public static prop dataType: DataType {
        get() {
            stream
        }
    }

    public func toString() {
        "DataInputStream"
    }
}

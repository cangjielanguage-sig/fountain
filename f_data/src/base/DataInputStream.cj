/*
Copyright (c) 2025 WuJingrun（吴京润）

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
package fountain::f_data.base

public class DataInputStream <: Data {
    public DataInputStream(public let data: InputStream){}

    public static func parse(_: String): Data {
        throw DataException()
    }
    public static func tryParse(_: String): ?Data {
        None<Data>
    }
    public func toString(){
        '_'
    }
}
extend File <: DataFields<File> {
    public func toData(): Data {
        DataInputStream(this)
    }
    public static func tryFromData(data: Data, flag: DataConversionFlag): Any {
        if (let d: DataInputStream <- data && let f: File <- d.data) {
            f
        } else if ((flag & IGNORE_FIELD_TYPE_NOT_MATCH) == 0){
            throw DataException('current data does not match to File')
        } else {
            None<File>
        }
    }
}
extend TcpSocket <: DataFields<TcpSocket> {
    public func toData(): Data {
        DataInputStream(this)
    }
    public static func tryFromData(data: Data, flag: DataConversionFlag): Any {
        if (let d: DataInputStream <- data && let s: TcpSocket <- d.data) {
            s
        } else if ((flag & IGNORE_FIELD_TYPE_NOT_MATCH) == 0){
            throw DataException('current data does not match to TcpSocket')
        } else {
            None<TcpSocket>
        }
    }
}
extend UnixSocket <: DataFields<UnixSocket>{
    public func toData(): Data {
        DataInputStream(this)
    }
    public static func tryFromData(data: Data, flag: DataConversionFlag): Any {
        if (let d: DataInputStream <- data && let f: UnixSocket <- d.data) {
            f
        } else if ((flag & IGNORE_FIELD_TYPE_NOT_MATCH) == 0){
            throw DataException('current data does not match to UnixSocket')
        } else {
            None<UnixSocket>
        }
    }
}
extend ByteBuffer <: DataFields<ByteBuffer> {
    public func toData(): Data {
        DataInputStream(this)
    }
    public static func tryFromData(data: Data, flag: DataConversionFlag): Any {
        if (let d: DataInputStream <- data && let f: ByteBuffer <- d.data) {
            f
        } else if ((flag & IGNORE_FIELD_TYPE_NOT_MATCH) == 0){
            throw DataException('current data does not match to ByteBuffer')
        } else {
            None<ByteBuffer>
        }
    }
}
extend<T> ChainedInputStream<T> <: DataFields<ChainedInputStream<T>> where T <: InputStream {
    public func toData(): Data {
        DataInputStream(this)
    }
    public static func tryFromData(data: Data, flag: DataConversionFlag): Any {
        if (let d: DataInputStream <- data && let ch: ChainedInputStream<T> <- d.data) {
            ch
        } else if ((flag & IGNORE_FIELD_TYPE_NOT_MATCH) == 0){
            throw DataException('current data does not match to ChainedInputStream')
        } else {
            None<ChainedInputStream<T>>
        }
    }
}
extend<T> BufferedInputStream<T> <: DataFields<BufferedInputStream<T>> where T <: InputStream {
    public func toData(): Data {
        DataInputStream(this)
    }
    public static func tryFromData(data: Data, flag: DataConversionFlag): Any {
        if (let d: DataInputStream <- data && let buf: BufferedInputStream<T> <- d.data) {
            buf
        } else if ((flag & IGNORE_FIELD_TYPE_NOT_MATCH) == 0){
            throw DataException('current data does not match to BufferedInputStream')
        } else {
            None<BufferedInputStream<T>>
        }
    }
}
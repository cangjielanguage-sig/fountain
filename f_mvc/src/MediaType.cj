/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_mvc

public abstract class MediaType <: ToString & Hashable & Equatable<MediaType> {
    protected var hash = 0
    public MediaType(public let mediaType: String) {}
    public open func toString(): String {
        mediaType
    }
    public open func hashCode(): Int64 {
        if (hash == 0) {
            hash = HashBuilder().append(mediaType).build()
        }
        hash
    }
    public func make(mediaType: String): MediaType
    public open operator func ==(other: MediaType): Bool {
        this.mediaType == other.mediaType
    }
    public func fromDataFields<T>(data: T): Array<Byte> where T <: DataFields<T> {
        fromData(data.toData())
    }
    public open func fromData(data: Data): Array<Byte>
    public open func toData(data: Array<Byte>): Data
    public open func toData(input: InputStream): Data {
        let list = ArrayList<Byte>()
        let buf = Array<Byte>(1024, repeat: 0)
        while (let len <- input.read(buf)) {
            if (len > 0) {
                list.add(all: buf[0..len])
            } else {
                break
            }
        }
        toData(list.unsafeData())
    }
    public open func toData(data: String): Data {
        toData(data.toArray())
    }
    public func toDataFields<T>(data: Array<Byte>): T where T <: DataFields<T> {
        T.fromData(toData(data))
    }
    public func toDataFields<T>(input: InputStream): T where T <: DataFields<T> {
        T.fromData(toData(input))
    }
    public func toDataFields<T>(data: String): T where T <: DataFields<T> {
        T.fromData(toData(data))
    }
}

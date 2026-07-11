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
package fountain::fleet.base

import fountain::f_data.macros.*

@DataAssist[fields]
public class FleetDataMessage {
    public var path: String
    public var data: Array<Byte>
    public var expire: Duration

    public init(){
        this('')
    }
    public init(path: String){
        this(path, [])
    }
    public init(path: String, data: Array<Byte>, expire!: Duration = Duration.Zero){
        this.path = path
        this.data = data
        this.expire = expire
    }
    public init(path: String, data: Array<Byte>, expireAt: DateTime){
        this(path, data, expire: expireAt - DateTime.now())
    }
    public init(path: String, data: Data, expire!: Duration = Duration.Zero){
        this(path, encode(data), expire: expire)
    }
    public init(path: String, data: Data, expireAt: DateTime){
        this(path, encode(data), expireAt)
    }

    public static func new<T>(path: String, data: T, expire!: Duration = Duration.Zero): FleetDataMessage where T <: DataFields<T> {
        FleetDataMessage(path, encode(data), expire: expire)
    }
    public static func new<T>(path: String, data: T, expireAt: DateTime): FleetDataMessage where T <: DataFields<T> {
        FleetDataMessage(path, encode(data), expireAt)
    }
    private static func encode(data: Data): Array<Byte> {
        let input = ByteBuffer()
        DefaultCodec().encode(data).finish().copy(to: input, closeFromOnEnd: true, closeToOnEnd: false)
        input.bytes()
    }
    private static func encode<T>(data: T): Array<Byte> where T <: DataFields<T> {
        encode(data.toData())
    }
}
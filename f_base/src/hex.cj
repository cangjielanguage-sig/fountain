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
package fountain::f_base

private let hex = '0123456789abcdef'.toRuneArray()
private let hexmap = {=>
    let map = HashMap<Byte, Byte>()
    for(i in 0 .. hex.size){
        map[UInt8(UInt32(hex[i]))] = UInt8(i)
    }
    map
}()
public func toHex(b: Byte): String {
    '${hex[Int64(b >> 4)]}${hex[Int64(b & 0x0f)]}'
}
public func fromHex(s: String): Byte {
    if(s.size > 2){
        throw IllegalArgumentException(s)
    }
    (hexmap[s[0]] << 4) | hexmap[s[1]]
}
/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    utility is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
*/
package f_jwt

import stdx.encoding.base64.*
import stdx.encoding.hex.*
import f_jwt.exception.*

func fromBase64(src: String): Array<Byte> {
    fromBase64String(src).getOrThrow {JWTException('${src} is not base64')}
}
func fromBase64ToString(src: String){
    String.fromUtf8(fromBase64(src))
}
func fromHex(src: String): Array<Byte> {
    fromHexString(src).getOrThrow {JWTException('${src} is not hex')}
}
func toBase64(src: Array<Byte>): String {
    toBase64String(src)
}
func toBase64(src: String): String {
    toBase64(unsafe{src.rawData()})
}
func bytesForSign(header: String, payload: String): Array<Byte> {
    bytesForSign(unsafe{header.rawData()}, unsafe{payload.rawData()})
}
func bytesForSign(header: Array<Byte>, payload: Array<Byte>): Array<Byte> {
    let headerSize = header.size
    Array<Byte>(headerSize + payload.size){i =>
        if (i < headerSize) {
            header[i]
        } else {
            payload[i - headerSize]
        }
    }
}
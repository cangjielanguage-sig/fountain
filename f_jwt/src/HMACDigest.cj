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

import std.crypto.digest.Digest
import crypto.digest.{HMAC, HashType}

public class HMACDigest <: Digest {
    public HMACDigest(private let hmac: HMAC){}
    public init(key: Array<Byte>, algorithm: HashType){
        this(HMAC(key, algorithm))
    }
    public prop size: Int64 {
        get() {
            hmac.size
        }
    }
    public prop blockSize: Int64 {
        get() {
            hmac.blockSize
        }
    }
    public func write(buffer: Array<Byte>): Unit {
        hmac.write(buffer)
    }
    public func finish(): Array<Byte> {
        hmac.finish()
    }
    public func reset(): Unit {
        hmac.reset()
    }
}

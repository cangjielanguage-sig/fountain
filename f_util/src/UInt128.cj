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
package fountain::f_util

import std.convert.*
import stdx.encoding.hex.*
import fountain::f_base.*
import fountain::f_data.*
import fountain::f_util.exception.HashException

public struct UInt128 <: ToString & Hashable & Comparable<UInt128> & DataParsable<UInt128> & Parsable<UInt128> {
    UInt128(
        public let left: UInt64,
        public let right: UInt64
    ) {}
    public func toString(): String {
        toHexString(toBytes())
    }
    public static func tryParse(s: String): ?UInt128 {
        match (fromHexString(s)) {
            case Some(x) => fromBytes(x)
            case _ => None
        }
    }
    public static func parse(s: String): UInt128 {
        tryParse(s).getOrThrow()
    }
    public func hashCode(): Int64 {
        (left ^ right).toInt()
    }
    public func compare(other: UInt128): Ordering {
        match (this.left.compare(other.left)) {
            case EQ => this.right.compare(other.right)
            case x => x
        }
    }
    public func toBytes(): Array<Byte> {
        Array<Byte>(16) {
            i => if (i < 8) {
                UInt8(left >> ((7 - i) * 8))
            } else {
                UInt8(right >> ((15 - i) * 8))
            }
        }
    }
    public static func fromBytes(bytes: Array<Byte>): UInt128 {
        if (bytes.size != 16) {
            HashException("Invalid bytes length, expected 16 bytes, but it is ${bytes} which size is ${bytes.size}")
        }
        var left = 0u64
        var right = 0u64
        for (i in 0..bytes.size) {
            if (i < 8) {
                left |= UInt64(bytes[i]) << UInt64((7 - i) * 8)
            } else {
                right |= UInt64(bytes[i]) << UInt64((15 - i) * 8)
            }
        }
        UInt128(left, right)
    }
}

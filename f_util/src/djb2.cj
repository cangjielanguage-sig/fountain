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

import fountain::f_base.*
/**
 * 计算 bytes 的哈希值（DJB2 算法）
 */
@OverflowWrapping
public func djb2(bytes: Array<Byte>): UInt64 {
    var h: UInt64 = 5381
    for (b in bytes) {
        h = ((h << 5) + h) + UInt64(b)
    }
    h
}
/**
 * 计算 s 的哈希值（DJB2 算法）
 */
public func djb2(s: String): UInt64 {
    djb2(s.unsafeBytes())
}

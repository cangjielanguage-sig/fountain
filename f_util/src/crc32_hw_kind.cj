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

/** 可由生成式硬件路径加速的 CRC-32 变体；其它变体一律走纯软件。 */
enum CrcHwKind <: Equatable<CrcHwKind> {
    | Iso
    | Crc32c
    | Unsupported

    public operator func ==(other: CrcHwKind): Bool {
        match (this) {
            case Iso => match (other) {
                case Iso => true
                case _ => false
            }
            case Crc32c => match (other) {
                case Crc32c => true
                case _ => false
            }
            case Unsupported => match (other) {
                case Unsupported => true
                case _ => false
            }
        }
    }

    public operator func !=(other: CrcHwKind): Bool {
        !(this == other)
    }
}

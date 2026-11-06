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

/**
 * 非 Linux 平台的 CRC-64 折叠核空实现：永远没有 native 路径，全部走表驱动。
 */
@When[os != "Linux"]
class Crc64Hw {
    static func available(): Bool {
        false
    }

    static func update(_: UInt64, _: Array<Byte>, _: Int64): ?UInt64 {
        None
    }

    static func setNativeEnabled(_: Bool): Unit {}

    static func resetForTest(): Unit {}
}

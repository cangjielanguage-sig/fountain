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
 * 非「Linux x86_64」平台的空实现：永远没有 native 路径，全部走纯软件。
 *
 * aarch64 的生成式路径在 Phase 1 后续补上；在此之前它也走这个 stub。
 */
@When[os != "Linux" || arch != "x86_64"]
class Crc32Hw {
    static func available(): Bool {
        false
    }

    static func availableFor(_: CrcHwKind): Bool {
        false
    }

    static func update(_: CrcHwKind, _: UInt32, _: Array<Byte>): ?UInt32 {
        None
    }

    static func setNativeEnabled(_: Bool): Unit {}

    static func resetForTest(): Unit {}
}

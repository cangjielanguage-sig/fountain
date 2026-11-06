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
 * 非目标平台的 CRC-64 折叠核空实现：永远没有 native 路径，全部走表驱动。
 *
 * 覆盖范围是"非 Linux **或** Linux 上不是 aarch64/x86_64"——后者若漏掉，
 * `CrcEngine` 引用 `Crc64Hw` 时会因缺少定义而编译失败（riscv64 / loongarch64）。
 */
@When[os != "Linux" || (arch != "aarch64" && arch != "x86_64")]
class Crc64Hw {
    static func available(): Bool {
        false
    }

    static func supports(_: UInt64): Bool {
        false
    }

    static func supportsNormal(_: UInt64): Bool {
        false
    }

    static func updateNormal(_: UInt64, _: Array<Byte>, _: Int64): ?UInt64 {
        None
    }

    static func update(_: UInt64, _: Array<Byte>, _: Int64, _: UInt64): ?UInt64 {
        None
    }

    static func setNativeEnabled(_: Bool): Unit {}

    static func resetForTest(): Unit {}

    static func lastUsedNativeForTest(): Bool {
        false
    }

    static func modeNameForTest(): String {
        "off"
    }

    static func forceAllocFailureForTest(_: Bool): Unit {}
}
